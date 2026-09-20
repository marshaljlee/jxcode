/*
 * JNI pty for JXCode on Android.
 *
 * Android has no posix_spawn pty helper, but bionic provides openpty/forkpty
 * in <pty.h>, which is what this uses. It is the equivalent of the macOS
 * build's PTYSession: fork a child onto a pty, hand the master fd back to
 * Kotlin, and let the caller pump bytes.
 *
 * The master is non-blocking so the reader loop can be woken on a timer and
 * cancelled without a signal; a read returning EIO means the child exited.
 */
#include <jni.h>
#include <pty.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

typedef struct {
    int master;
    pid_t pid;
} JXPty;

static void throw_by_name(JNIEnv *env, const char *name, const char *message) {
    jclass cls = (*env)->FindClass(env, name);
    if (cls != NULL) {
        (*env)->ThrowNew(env, cls, message);
    }
}

static char *dup_java_string(JNIEnv *env, jstring value) {
    if (value == NULL) return NULL;
    const char *chars = (*env)->GetStringUTFChars(env, value, NULL);
    if (chars == NULL) return NULL;
    char *copy = strdup(chars);
    (*env)->ReleaseStringUTFChars(env, value, chars);
    return copy;
}

static void free_array(char **array, int count) {
    for (int i = 0; i < count; i++) free(array[i]);
    free(array);
}

static char **to_string_array(JNIEnv *env, jobjectArray source) {
    if (source == NULL) return NULL;
    jsize length = (*env)->GetArrayLength(env, source);
    char **result = calloc((size_t) length + 1, sizeof(char *));
    if (result == NULL) return NULL;
    for (jsize i = 0; i < length; i++) {
        jstring item = (jstring) (*env)->GetObjectArrayElement(env, source, i);
        result[i] = dup_java_string(env, item);
        (*env)->DeleteLocalRef(env, item);
    }
    return result;
}

JNIEXPORT jlong JNICALL
Java_com_jxcode_android_terminal_PtyNative_spawn(
        JNIEnv *env, jclass cls,
        jstring jcommand, jobjectArray jargs, jobjectArray jenv,
        jstring jcwd, jint rows, jint cols) {

    (void) cls;
    char *command = dup_java_string(env, jcommand);
    char *cwd = dup_java_string(env, jcwd);
    char **args = to_string_array(env, jargs);
    char **environment = to_string_array(env, jenv);

    int argCount = 1;
    if (args != NULL) {
        while (args[argCount - 1] != NULL) argCount++;
    }

    char **argv = calloc((size_t) argCount + 1, sizeof(char *));
    argv[0] = command;
    if (args != NULL) {
        for (int i = 1; i < argCount; i++) argv[i] = args[i - 1];
    }

    struct winsize window_size;
    memset(&window_size, 0, sizeof(window_size));
    window_size.ws_row = (unsigned short) (rows > 0 ? rows : 24);
    window_size.ws_col = (unsigned short) (cols > 0 ? cols : 80);

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &window_size);

    if (pid < 0) {
        free(argv);
        if (args != NULL) free_array(args, argCount - 1);
        if (environment != NULL) {
            int count = 0;
            while (environment[count] != NULL) count++;
            free_array(environment, count);
        }
        free(command);
        free(cwd);
        throw_by_name(env, "java/io/IOException", "forkpty failed");
        return 0L;
    }

    if (pid == 0) {
        // Child. Restore default handling: the JVM leaves signals blocked or
        // ignored, and a shell that cannot receive SIGINT behaves strangely.
        signal(SIGPIPE, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);

        if (cwd != NULL) chdir(cwd);

        if (environment != NULL) {
            execve(command, argv, environment);
        } else {
            execv(command, argv);
        }
        // Fall back to a PATH search, then give up loudly: a silent _exit here
        // shows up as a terminal that simply never prints anything.
        execvp(command, argv);
        _exit(127);
    }

    int flags = fcntl(master, F_GETFL, 0);
    if (flags >= 0) fcntl(master, F_SETFL, flags | O_NONBLOCK);

    JXPty *pty = calloc(1, sizeof(JXPty));
    if (pty == NULL) {
        close(master);
        return 0L;
    }
    pty->master = master;
    pty->pid = pid;

    free(argv);
    if (args != NULL) free_array(args, argCount - 1);
    if (environment != NULL) {
        int count = 0;
        while (environment[count] != NULL) count++;
        free_array(environment, count);
    }
    free(command);
    free(cwd);

    return (jlong) (intptr_t) pty;
}

JNIEXPORT jint JNICALL
Java_com_jxcode_android_terminal_PtyNative_read(JNIEnv *env, jclass cls, jlong handle, jbyteArray jbuffer) {
    (void) cls;
    JXPty *pty = (JXPty *) (intptr_t) handle;
    if (pty == NULL) return -1;

    jsize capacity = (*env)->GetArrayLength(env, jbuffer);
    jbyte *bytes = (*env)->GetByteArrayElements(env, jbuffer, NULL);
    if (bytes == NULL) return -1;

    ssize_t read_count = read(pty->master, bytes, (size_t) capacity);
    (*env)->ReleaseByteArrayElements(env, jbuffer, bytes, 0);

    if (read_count > 0) return (jint) read_count;
    if (read_count == 0) return -1;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
    return -1; // EIO: the child closed the slave side.
}

JNIEXPORT jint JNICALL
Java_com_jxcode_android_terminal_PtyNative_write(JNIEnv *env, jclass cls, jlong handle, jbyteArray jdata) {
    (void) cls;
    JXPty *pty = (JXPty *) (intptr_t) handle;
    if (pty == NULL) return -1;

    jsize length = (*env)->GetArrayLength(env, jdata);
    jbyte *bytes = (*env)->GetByteArrayElements(env, jdata, NULL);
    if (bytes == NULL) return -1;

    ssize_t written = write(pty->master, bytes, (size_t) length);
    (*env)->ReleaseByteArrayElements(env, jdata, bytes, JNI_ABORT);

    if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    return (jint) (written < 0 ? -1 : written);
}

JNIEXPORT void JNICALL
Java_com_jxcode_android_terminal_PtyNative_resize(JNIEnv *env, jclass cls, jlong handle, jint rows, jint cols) {
    (void) env; (void) cls;
    JXPty *pty = (JXPty *) (intptr_t) handle;
    if (pty == NULL) return;

    struct winsize window_size;
    memset(&window_size, 0, sizeof(window_size));
    window_size.ws_row = (unsigned short) rows;
    window_size.ws_col = (unsigned short) cols;
    ioctl(pty->master, TIOCSWINSZ, &window_size);
}

JNIEXPORT jint JNICALL
Java_com_jxcode_android_terminal_PtyNative_waitFor(JNIEnv *env, jclass cls, jlong handle, jint timeoutMs) {
    (void) env; (void) cls;
    JXPty *pty = (JXPty *) (intptr_t) handle;
    if (pty == NULL) return -1;

    int total = 0;
    while (total <= timeoutMs) {
        int status = 0;
        pid_t result = waitpid(pty->pid, &status, WNOHANG);
        if (result == pty->pid) {
            if (WIFEXITED(status)) return WEXITSTATUS(status);
            if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
            return -1;
        }
        if (result < 0) return -1;
        usleep(50 * 1000);
        total += 50;
    }
    return -1;
}

JNIEXPORT jint JNICALL
Java_com_jxcode_android_terminal_PtyNative_signal(JNIEnv *env, jclass cls, jlong handle, jint signalNumber) {
    (void) env; (void) cls;
    JXPty *pty = (JXPty *) (intptr_t) handle;
    if (pty == NULL) return -1;
    return kill(pty->pid, signalNumber);
}

JNIEXPORT void JNICALL
Java_com_jxcode_android_terminal_PtyNative_close(JNIEnv *env, jclass cls, jlong handle) {
    (void) env; (void) cls;
    JXPty *pty = (JXPty *) (intptr_t) handle;
    if (pty == NULL) return;
    close(pty->master);
    free(pty);
}
