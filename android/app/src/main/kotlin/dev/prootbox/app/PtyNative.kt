package dev.prootbox.app

/**
 * JNI surface implemented in `src/main/cpp/pty_spawn.c`.
 *
 * The Kotlin side owns the threading and the Flutter channel; C only does the
 * parts Java cannot express: `posix_openpt()` + `fork()`/`execve()`.
 */
internal object PtyNative {

    init {
        System.loadLibrary("prootbox_pty")
    }

    /**
     * Allocates a PTY pair, forks and execs [executable] with the slave as
     * stdin/stdout/stderr and as its controlling terminal.
     *
     * @return `[sessionFd, childPid]` on success, `[-errno, -1]` on failure.
     */
    external fun nativeSpawnPty(
        executable: String,
        argv: Array<String>,
        envp: Array<String>,
        workingDirectory: String?,
        rows: Int,
        cols: Int,
    ): IntArray

    /** @return bytes read, `0` on EOF/closed pty, `-1` on error. */
    external fun nativeRead(fd: Int, buffer: ByteArray): Int

    external fun nativeWrite(fd: Int, buffer: ByteArray, offset: Int, length: Int): Int

    external fun nativeResize(fd: Int, rows: Int, cols: Int): Int

    external fun nativeClose(fd: Int)

    /** Blocks until [pid] exits. @return exit code, or `128 + signal`. */
    external fun nativeWaitPid(pid: Int): Int

    /** Sends [signal] to [pid]; a negative pid targets a process group. */
    external fun nativeKill(pid: Int, signal: Int): Int

    /** @return `0` when the path is executable, otherwise an errno value. */
    external fun nativeIsExecutable(path: String): Int
}
