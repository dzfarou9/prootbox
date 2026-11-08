/*
 * pty_spawn.c — PTY allocation + fork/exec for the ProotBox sandbox.
 *
 * Why native code at all?
 *
 *   Dart's Process.start() gives you pipes, not a pseudo-terminal. An
 *   *interactive* guest shell needs a real tty: line discipline, echo, window
 *   size (SIGWINCH), job control, Ctrl-C as a signal rather than a byte, and
 *   full-screen TUIs (vim, htop, OpenCode). Those only work on a pty slave
 *   that the child owns as its controlling terminal.
 *
 *   Java has no portable way to (a) allocate a pty pair and (b) hand the slave
 *   fd to a child as fd 0/1/2, so this file does the classic
 *   posix_openpt()/grantpt()/unlockpt() + fork() dance and leaves the master
 *   fd with the JVM, which then uses read()/write() on it.
 *
 * Android specifics handled here:
 *   - the child resets every signal handler to SIG_DFL (the JVM installs
 *     handlers for SIGPIPE/SIGQUIT/... and ignores some of them),
 *   - the child calls setsid() + TIOCSCTTY so job control works,
 *   - JNI strings are copied with strdup() before fork(), because after
 *     fork() the parent may legally release them while the child is still
 *     between fork and execve.
 */

#define _GNU_SOURCE
#include <jni.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

/* bionic declares these in <stdlib.h> on API 21+; redeclaring an identical
 * prototype is legal C and keeps this file independent of header details. */
extern int posix_openpt(int flags);
extern int grantpt(int fd);
extern int unlockpt(int fd);
extern char *ptsname(int fd);

/* ------------------------------------------------------------------ helpers */

static char **to_c_array(JNIEnv *env, jobjectArray array) {
    if (array == NULL) {
        return NULL;
    }
    jsize length = (*env)->GetArrayLength(env, array);
    char **result = (char **) calloc((size_t) length + 1, sizeof(char *));
    if (result == NULL) {
        return NULL;
    }
    for (jsize i = 0; i < length; i++) {
        jstring item = (jstring) (*env)->GetObjectArrayElement(env, array, i);
        const char *utf = NULL;
        if (item != NULL) {
            utf = (*env)->GetStringUTFChars(env, item, NULL);
        }
        result[i] = strdup(utf != NULL ? utf : "");
        if (utf != NULL) {
            (*env)->ReleaseStringUTFChars(env, item, utf);
        }
        if (item != NULL) {
            (*env)->DeleteLocalRef(env, item);
        }
        if (result[i] == NULL) {
            /* Out of memory: free what we built and give up. */
            for (jsize j = 0; j < i; j++) {
                free(result[j]);
            }
            free(result);
            return NULL;
        }
    }
    return result;
}

static void free_c_array(char **array) {
    if (array == NULL) {
        return;
    }
    for (char **cursor = array; *cursor != NULL; cursor++) {
        free(*cursor);
    }
    free(array);
}

/*
 * Restore default signal dispositions and an empty signal mask. The JVM sets
 * SIGPIPE to SIG_IGN and blocks several signals in its threads; inheriting
 * either makes a guest shell behave strangely (no SIGPIPE, no job control).
 */
static void child_reset_signals(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    for (int sig = 1; sig < 32; sig++) {
        sigaction(sig, &action, NULL);
    }
    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, NULL);
}

/* ------------------------------------------------------------------- spawn */

JNIEXPORT jintArray JNICALL
Java_dev_prootbox_app_PtyNative_nativeSpawnPty(JNIEnv *env, jobject thiz,
                                               jstring jexecutable,
                                               jobjectArray jargv,
                                               jobjectArray jenvp,
                                               jstring jworking_directory,
                                               jint rows, jint cols) {
    (void) thiz;
    jintArray result = (*env)->NewIntArray(env, 2);
    if (result == NULL) {
        return NULL;
    }

    jint outcome[2] = {-1, -1};
    int master = -1;
    int slave = -1;
    int error = 0;
    char *executable = NULL;
    char *working_directory = NULL;
    char **argv = NULL;
    char **envp = NULL;

    /* Copy everything out of the JVM before fork(). */
    const char *exe_utf = (*env)->GetStringUTFChars(env, jexecutable, NULL);
    if (exe_utf == NULL) {
        error = ENOMEM;
        goto finish;
    }
    executable = strdup(exe_utf);
    (*env)->ReleaseStringUTFChars(env, jexecutable, exe_utf);
    if (executable == NULL) {
        error = ENOMEM;
        goto finish;
    }

    if (jworking_directory != NULL) {
        const char *cwd_utf =
            (*env)->GetStringUTFChars(env, jworking_directory, NULL);
        if (cwd_utf != NULL) {
            working_directory = strdup(cwd_utf);
            (*env)->ReleaseStringUTFChars(env, jworking_directory, cwd_utf);
        }
    }

    argv = to_c_array(env, jargv);
    envp = to_c_array(env, jenvp);
    if (argv == NULL || envp == NULL) {
        error = ENOMEM;
        goto finish;
    }

    master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) {
        error = errno;
        goto finish;
    }
    if (grantpt(master) != 0) {
        error = errno;
        goto finish;
    }
    if (unlockpt(master) != 0) {
        error = errno;
        goto finish;
    }

    char *slave_name = ptsname(master);
    if (slave_name == NULL) {
        error = errno != 0 ? errno : EIO;
        goto finish;
    }

    slave = open(slave_name, O_RDWR | O_NOCTTY);
    if (slave < 0) {
        error = errno;
        goto finish;
    }

    struct winsize window;
    memset(&window, 0, sizeof(window));
    window.ws_row = (unsigned short) (rows > 0 ? rows : 24);
    window.ws_col = (unsigned short) (cols > 0 ? cols : 80);
    ioctl(master, TIOCSWINSZ, &window);

    pid_t pid = fork();
    if (pid < 0) {
        error = errno;
        goto finish;
    }

    if (pid == 0) {
        /* ---- child: only async-signal-safe calls from here on ---- */
        setsid();
        ioctl(slave, TIOCSCTTY, 0);

        if (dup2(slave, STDIN_FILENO) < 0 ||
            dup2(slave, STDOUT_FILENO) < 0 ||
            dup2(slave, STDERR_FILENO) < 0) {
            _exit(126);
        }
        if (slave > STDERR_FILENO) {
            close(slave);
        }
        close(master);

        child_reset_signals();

        if (working_directory != NULL) {
            (void) chdir(working_directory);
        }

        execve(executable, argv, envp);

        /* execve failed — tell the user on the terminal, then bail out. */
        {
            const char message[] =
                "\r\nprootbox: failed to execute the PRoot binary "
                "(execve error). Rebuild with scripts/build-proot.sh.\r\n";
            ssize_t ignored = write(STDERR_FILENO, message, sizeof(message) - 1);
            (void) ignored;
        }
        _exit(127);
    }

    /* ---- parent ---- */
    close(slave);
    slave = -1;
    outcome[0] = (jint) master;
    outcome[1] = (jint) pid;
    master = -1; /* ownership moved to the JVM */

finish:
    if (master >= 0) {
        close(master);
    }
    if (slave >= 0) {
        close(slave);
    }
    free(executable);
    free(working_directory);
    free_c_array(argv);
    free_c_array(envp);

    if (outcome[0] < 0) {
        outcome[0] = -(error != 0 ? error : EIO);
        outcome[1] = -1;
    }

    (*env)->SetIntArrayRegion(env, result, 0, 2, outcome);
    return result;
}

/* ---------------------------------------------------------------- pty I/O */

JNIEXPORT jint JNICALL
Java_dev_prootbox_app_PtyNative_nativeRead(JNIEnv *env, jobject thiz, jint fd,
                                           jbyteArray buffer) {
    (void) thiz;
    jsize length = (*env)->GetArrayLength(env, buffer);
    if (length <= 0) {
        return 0;
    }

    jbyte *bytes = (*env)->GetByteArrayElements(env, buffer, NULL);
    if (bytes == NULL) {
        return -1;
    }

    ssize_t read_count;
    do {
        read_count = read((int) fd, bytes, (size_t) length);
    } while (read_count < 0 && errno == EINTR);

    (*env)->ReleaseByteArrayElements(env, buffer, bytes, 0);

    if (read_count < 0) {
        /* EIO is how a Linux pty master reports "all slaves closed". */
        return (errno == EIO || errno == EBADF) ? 0 : -1;
    }
    return (jint) read_count;
}

JNIEXPORT jint JNICALL
Java_dev_prootbox_app_PtyNative_nativeWrite(JNIEnv *env, jobject thiz, jint fd,
                                            jbyteArray buffer, jint offset,
                                            jint length) {
    (void) thiz;
    if (length <= 0) {
        return 0;
    }

    jbyte *bytes = (*env)->GetByteArrayElements(env, buffer, NULL);
    if (bytes == NULL) {
        return -1;
    }

    jint total = 0;
    while (total < length) {
        ssize_t written =
            write((int) fd, bytes + offset + total, (size_t) (length - total));
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (total == 0) {
                total = -1;
            }
            break;
        }
        total += (jint) written;
    }

    (*env)->ReleaseByteArrayElements(env, buffer, bytes, JNI_ABORT);
    return total;
}

JNIEXPORT jint JNICALL
Java_dev_prootbox_app_PtyNative_nativeResize(JNIEnv *env, jobject thiz, jint fd,
                                             jint rows, jint cols) {
    (void) env;
    (void) thiz;
    struct winsize window;
    memset(&window, 0, sizeof(window));
    window.ws_row = (unsigned short) (rows > 0 ? rows : 1);
    window.ws_col = (unsigned short) (cols > 0 ? cols : 1);
    return ioctl((int) fd, TIOCSWINSZ, &window) == 0 ? 0 : -errno;
}

JNIEXPORT void JNICALL
Java_dev_prootbox_app_PtyNative_nativeClose(JNIEnv *env, jobject thiz, jint fd) {
    (void) env;
    (void) thiz;
    if (fd >= 0) {
        close((int) fd);
    }
}

JNIEXPORT jint JNICALL
Java_dev_prootbox_app_PtyNative_nativeWaitPid(JNIEnv *env, jobject thiz,
                                              jint pid) {
    (void) env;
    (void) thiz;
    int status = 0;
    pid_t waited;
    do {
        waited = waitpid((pid_t) pid, &status, 0);
    } while (waited < 0 && errno == EINTR);

    if (waited < 0) {
        return -1;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return -1;
}

JNIEXPORT jint JNICALL
Java_dev_prootbox_app_PtyNative_nativeKill(JNIEnv *env, jobject thiz, jint pid,
                                           jint signal_number) {
    (void) env;
    (void) thiz;
    /* A negative pid targets the whole process group (the guest session). */
    return kill((pid_t) pid, signal_number) == 0 ? 0 : -errno;
}

JNIEXPORT jint JNICALL
Java_dev_prootbox_app_PtyNative_nativeIsExecutable(JNIEnv *env, jobject thiz,
                                                   jstring jpath) {
    (void) thiz;
    if (jpath == NULL) {
        return ENOENT;
    }
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    if (path == NULL) {
        return ENOMEM;
    }
    int rc = access(path, X_OK);
    int error = rc == 0 ? 0 : (errno != 0 ? errno : EACCES);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    return error;
}
