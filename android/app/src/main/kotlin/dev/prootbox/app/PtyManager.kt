package dev.prootbox.app

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Bridges Flutter to the native PTY.
 *
 * Responsibilities:
 *  - `open`: spawn PRoot on a fresh PTY (see `pty_spawn.c`),
 *  - a per-session reader thread that pumps master-fd bytes to Flutter,
 *  - writes on a background executor so a large paste never blocks the
 *    platform thread,
 *  - window-size changes (SIGWINCH inside the guest),
 *  - process-group teardown (SIGHUP/SIGTERM/SIGKILL).
 *
 * Event payloads (EventChannel `prootbox/pty/events`):
 *   `{type: "output", id: Int, data: ByteArray}`
 *   `{type: "exit",   id: Int, code: Int}`
 */
class PtyManager : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private companion object {
        const val TAG = "ProotBoxPty"
        const val READ_BUFFER_SIZE = 16 * 1024
        const val SIGHUP = 1
        const val SIGKILL = 9
    }

    private class Session(val id: Int, val fd: Int, val pid: Int) {
        val writer = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "prootbox-pty-$id-writer").apply { isDaemon = true }
        }

        @Volatile
        var disposed = false
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val sessions = ConcurrentHashMap<Int, Session>()
    private val nextId = AtomicInteger(1)

    @Volatile
    private var sink: EventChannel.EventSink? = null

    // ------------------------------------------------------------ EventChannel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ------------------------------------------------------------ MethodChannel

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> open(call, result)
            "write" -> write(call, result)
            "resize" -> resize(call, result)
            "kill" -> kill(call, result)
            "close" -> closeSession(call, result)
            else -> result.notImplemented()
        }
    }

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        val executable = call.argument<String>("executable")
        if (executable.isNullOrBlank()) {
            result.error("bad_args", "executable is required", null)
            return
        }

        val arguments = (call.argument<List<*>>("arguments") ?: emptyList<Any?>())
            .map { it?.toString() ?: "" }
        val environment = (call.argument<Map<*, *>>("environment") ?: emptyMap<Any?, Any?>())
            .entries
            .mapNotNull { entry ->
                val key = entry.key?.toString() ?: return@mapNotNull null
                "$key=${entry.value}"
            }
        val workingDirectory = call.argument<String>("workingDirectory")
        val rows = call.argument<Int>("rows") ?: 24
        val cols = call.argument<Int>("cols") ?: 80

        val argv = ArrayList<String>(arguments.size + 1)
        argv.add(executable)
        argv.addAll(arguments)

        val outcome: IntArray = try {
            PtyNative.nativeSpawnPty(
                executable,
                argv.toTypedArray(),
                environment.toTypedArray(),
                workingDirectory,
                rows,
                cols,
            )
        } catch (throwable: Throwable) {
            Log.e(TAG, "native spawn threw", throwable)
            result.error("spawn_failed", throwable.message ?: "native spawn failed", null)
            return
        }

        val fd = outcome.getOrNull(0) ?: -1
        val pid = outcome.getOrNull(1) ?: -1
        if (fd < 0 || pid <= 0) {
            val errno = if (fd < 0) -fd else -1
            Log.e(TAG, "spawn failed errno=$errno executable=$executable")
            result.error(
                "spawn_failed",
                "could not start '$executable' (errno $errno)",
                errno,
            )
            return
        }

        val id = nextId.getAndIncrement()
        val session = Session(id, fd, pid)
        sessions[id] = session
        startReader(session)
        Log.i(TAG, "session $id started pid=$pid fd=$fd exec=$executable")
        result.success(listOf(id, pid))
    }

    private fun startReader(session: Session) {
        Thread({
            val buffer = ByteArray(READ_BUFFER_SIZE)
            while (!session.disposed) {
                val read = try {
                    PtyNative.nativeRead(session.fd, buffer)
                } catch (throwable: Throwable) {
                    Log.e(TAG, "read failed on session ${session.id}", throwable)
                    -1
                }
                if (read <= 0) {
                    break
                }
                val chunk = buffer.copyOf(read)
                post {
                    sink?.success(
                        mapOf(
                            "type" to "output",
                            "id" to session.id,
                            "data" to chunk,
                        ),
                    )
                }
            }

            val code = try {
                PtyNative.nativeWaitPid(session.pid)
            } catch (throwable: Throwable) {
                -1
            }

            sessions.remove(session.id)
            runCatching { session.writer.shutdownNow() }
            runCatching { PtyNative.nativeClose(session.fd) }

            post {
                sink?.success(
                    mapOf(
                        "type" to "exit",
                        "id" to session.id,
                        "code" to code,
                    ),
                )
            }
        }, "prootbox-pty-${session.id}-reader").apply { isDaemon = true }.start()
    }

    private fun write(call: MethodCall, result: MethodChannel.Result) {
        val session = sessionFor(call, result) ?: return
        val data = call.argument<ByteArray>("data")
        if (data == null || data.isEmpty()) {
            result.success(0)
            return
        }
        session.writer.execute {
            val written = try {
                PtyNative.nativeWrite(session.fd, data, 0, data.size)
            } catch (throwable: Throwable) {
                -1
            }
            post {
                if (written < 0) {
                    result.error("write_failed", "PTY write failed", written)
                } else {
                    result.success(written)
                }
            }
        }
    }

    private fun resize(call: MethodCall, result: MethodChannel.Result) {
        val session = sessionFor(call, result) ?: return
        val rows = call.argument<Int>("rows") ?: 24
        val cols = call.argument<Int>("cols") ?: 80
        PtyNative.nativeResize(session.fd, rows, cols)
        result.success(null)
    }

    private fun kill(call: MethodCall, result: MethodChannel.Result) {
        val session = sessionFor(call, result) ?: return
        val signal = call.argument<Int>("signal") ?: SIGKILL
        // Negative pid => signal the whole guest process group.
        PtyNative.nativeKill(-session.pid, signal)
        result.success(null)
    }

    private fun closeSession(call: MethodCall, result: MethodChannel.Result) {
        val session = sessionFor(call, result) ?: return
        PtyNative.nativeKill(-session.pid, SIGHUP)
        result.success(null)
    }

    private fun sessionFor(call: MethodCall, result: MethodChannel.Result): Session? {
        val id = call.argument<Int>("id")
        if (id == null) {
            result.error("bad_args", "id is required", null)
            return null
        }
        val session = sessions[id]
        if (session == null) {
            result.error("no_session", "session $id is not running", null)
            return null
        }
        return session
    }

    private fun post(block: () -> Unit) {
        mainHandler.post { block() }
    }

    /** Kills every guest session. Called when the Flutter engine is detached. */
    fun dispose() {
        for (session in sessions.values) {
            session.disposed = true
            runCatching { PtyNative.nativeKill(-session.pid, SIGKILL) }
            runCatching { session.writer.shutdownNow() }
            runCatching { PtyNative.nativeClose(session.fd) }
        }
        sessions.clear()
        sink = null
    }
}
