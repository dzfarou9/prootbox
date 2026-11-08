package dev.prootbox.app

import android.content.Context
import android.os.Build
import android.system.ErrnoException
import android.system.Os
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Platform services the Dart side cannot implement itself:
 *
 *  - `deviceInfo`: ABI/API level and — crucially —
 *    `ApplicationInfo.nativeLibraryDir`, the only directory on Android 10+
 *    whose files this process is allowed to `execve`,
 *  - `isExecutable` / `exists`: preflight checks that turn an opaque
 *    "sandbox won't start" into a precise diagnostic,
 *  - `chmod`: Dart has no `chmod`, and a rootfs is useless without the mode
 *    bits recorded in its tar archive.
 */
class NativeSupport(private val context: Context) : MethodChannel.MethodCallHandler {

    private companion object {
        const val TAG = "ProotBoxNative"
        const val PERMISSION_MASK = 0x1FF // 0777
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceInfo" -> result.success(deviceInfo())
            "isExecutable" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.success(false)
                } else {
                    result.success(PtyNative.nativeIsExecutable(path) == 0)
                }
            }

            "exists" -> {
                val path = call.argument<String>("path")
                result.success(path != null && File(path).exists())
            }

            "chmod" -> result.success(applyModes(call))
            else -> result.notImplemented()
        }
    }

    /**
     * Applies `[path, mode]` pairs. Returns how many succeeded; failures are
     * logged rather than fatal (a read-only or already-correct path is fine).
     */
    private fun applyModes(call: MethodCall): Int {
        val entries = call.argument<List<*>>("entries") ?: return 0
        var applied = 0
        for (entry in entries) {
            val pair = entry as? List<*> ?: continue
            val path = pair.getOrNull(0) as? String ?: continue
            val mode = (pair.getOrNull(1) as? Number)?.toInt() ?: continue
            try {
                Os.chmod(path, mode and PERMISSION_MASK)
                applied++
            } catch (error: ErrnoException) {
                Log.w(TAG, "chmod failed for $path: errno=${error.errno}")
            } catch (error: Throwable) {
                Log.w(TAG, "chmod failed for $path", error)
            }
        }
        return applied
    }

    private fun deviceInfo(): Map<String, Any> {
        val applicationInfo = context.applicationInfo
        val abis = Build.SUPPORTED_ABIS?.toList() ?: emptyList()
        return mapOf(
            "nativeLibraryDir" to (applicationInfo.nativeLibraryDir ?: ""),
            "packageName" to context.packageName,
            "abi" to (abis.firstOrNull() ?: ""),
            "supportedAbis" to abis,
            "sdkInt" to Build.VERSION.SDK_INT,
            "model" to listOf(Build.MANUFACTURER, Build.MODEL)
                .filter { it.isNotBlank() }
                .joinToString(" ")
                .trim(),
        )
    }
}
