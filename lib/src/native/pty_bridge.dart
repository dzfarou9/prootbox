import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/logger.dart';

/// Raised when the native PTY/PRoot launcher fails.
class PtyException implements Exception {
  const PtyException(this.message, {this.errno});

  final String message;
  final int? errno;

  @override
  String toString() => message;
}

/// A running pseudo-terminal session backed by Kotlin + a C `forkpty`-style
/// spawn.
///
/// Data flows:
///
///     guest -> pty slave -> pty master -> nativeRead() -> EventChannel -> here
///     here  -> MethodChannel -> nativeWrite() -> pty master -> guest
///
/// PTY (not `Process.start` pipes) is what makes an interactive shell, job
/// control, `SIGWINCH`, line editing and full-screen TUIs such as OpenCode work.
class PtySession {
  PtySession._(this._bridge, this.id, this.pid);

  final PtyBridge _bridge;

  /// Native session id.
  final int id;

  /// Host PID of the `proot` process (session leader of the guest).
  final int pid;

  final StreamController<List<int>> _output =
      StreamController<List<int>>.broadcast();
  final Completer<int> _exit = Completer<int>();

  /// Raw guest output. Feed through `utf8.decoder` for text.
  Stream<List<int>> get output => _output.stream;

  /// Completes with the guest's exit code (or `128 + signal`).
  Future<int> get exitCode => _exit.future;

  bool get hasExited => _exit.isCompleted;

  Future<void> write(List<int> data) => _bridge._write(id, data);

  Future<void> writeString(String data) =>
      _bridge._write(id, utf8.encode(data));

  Future<void> resize({required int rows, required int cols}) =>
      _bridge._resize(id, rows, cols);

  /// Sends `SIGTERM` to the whole guest process group.
  Future<void> terminate() => _bridge._kill(id, 15);

  /// Sends `SIGKILL` to the whole guest process group.
  Future<void> kill() => _bridge._kill(id, 9);

  /// `SIGHUP` — closes the shell like a hangup, so the reader thread hits EOF.
  Future<void> close() => _bridge._close(id);

  void _addOutput(List<int> chunk) {
    if (!_output.isClosed) {
      _output.add(chunk);
    }
  }

  void _finish(int code) {
    if (!_exit.isCompleted) {
      _exit.complete(code);
    }
    if (!_output.isClosed) {
      _output.close();
    }
  }
}

/// Owns the platform channels and dispatches native events to sessions.
class PtyBridge {
  PtyBridge({MethodChannel? methodChannel, EventChannel? eventChannel})
      : _method = methodChannel ?? const MethodChannel('prootbox/pty'),
        _events = eventChannel ?? const EventChannel('prootbox/pty/events');

  final MethodChannel _method;
  final EventChannel _events;

  final Map<int, PtySession> _sessions = <int, PtySession>{};
  StreamSubscription<Object?>? _subscription;

  /// Spawns `executable` with [arguments] and a dedicated PTY.
  ///
  /// [executable] must live somewhere the kernel lets this process execute:
  /// on Android 10+ that means `ApplicationInfo.nativeLibraryDir`.
  Future<PtySession> spawn({
    required String executable,
    List<String> arguments = const <String>[],
    Map<String, String> environment = const <String, String>{},
    required String workingDirectory,
    int rows = 24,
    int cols = 80,
  }) async {
    _ensureListener();

    final List<Object?>? raw;
    try {
      raw = await _method.invokeMethod<List<Object?>>('open', <String, dynamic>{
        'executable': executable,
        'arguments': arguments,
        'environment': environment,
        'workingDirectory': workingDirectory,
        'rows': rows,
        'cols': cols,
      });
    } on MissingPluginException catch (error) {
      throw PtyException(
          'Native PTY bridge is not available: ${error.message}');
    } on PlatformException catch (error) {
      final Object? details = error.details;
      throw PtyException(
        error.message ??
            'Failed to start the Linux environment (${error.code})',
        errno: details is int ? details : null,
      );
    }

    if (raw == null || raw.length < 2) {
      throw const PtyException('Native PTY bridge returned an invalid handle');
    }

    final int id = (raw[0] as num).toInt();
    final int pid = (raw[1] as num).toInt();
    if (id < 0 || pid <= 0) {
      final int errno = id < 0 ? -id : -1;
      throw PtyException(
        'Could not start the sandbox: ${describeErrno(errno)}',
        errno: errno,
      );
    }

    final PtySession session = PtySession._(this, id, pid);
    _sessions[id] = session;
    AppLogger.instance.log('pty: spawned pid=$pid session=$id exe=$executable');
    return session;
  }

  void _ensureListener() {
    if (_subscription != null) {
      return;
    }
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.instance
            .logError('pty event stream failed', error, stackTrace);
      },
    );
  }

  void _onEvent(Object? event) {
    if (event is! Map) {
      return;
    }
    final Object? rawId = event['id'];
    final int id = rawId is num ? rawId.toInt() : -1;
    final PtySession? session = _sessions[id];
    if (session == null) {
      return;
    }

    switch (event['type']) {
      case 'output':
        final Object? data = event['data'];
        if (data is Uint8List) {
          session._addOutput(data);
        } else if (data is List) {
          session._addOutput(data.cast<int>());
        }
      case 'exit':
        _sessions.remove(id);
        final Object? code = event['code'];
        session._finish(code is num ? code.toInt() : -1);
        AppLogger.instance.log('pty: session $id exited with $code');
    }
  }

  Future<void> _write(int id, List<int> data) async {
    if (data.isEmpty) {
      return;
    }
    final PtySession? session = _sessions[id];
    if (session == null) {
      return;
    }
    try {
      await _method.invokeMethod<int>('write', <String, dynamic>{
        'id': id,
        'data': data is Uint8List ? data : Uint8List.fromList(data),
      });
    } on PlatformException catch (error) {
      // The guest can exit between a keystroke and the write; that is normal.
      AppLogger.instance.log('pty: write to $id failed: ${error.message}');
    } on MissingPluginException {
      // Ignore: the activity is going away.
    }
  }

  Future<void> _resize(int id, int rows, int cols) async {
    if (!_sessions.containsKey(id)) {
      return;
    }
    try {
      await _method.invokeMethod<void>('resize', <String, dynamic>{
        'id': id,
        'rows': rows,
        'cols': cols,
      });
    } on PlatformException {
      // Resizing a dead session is harmless.
    } on MissingPluginException {
      // Ignore.
    }
  }

  Future<void> _kill(int id, int signal) async {
    try {
      await _method.invokeMethod<void>('kill', <String, dynamic>{
        'id': id,
        'signal': signal,
      });
    } on PlatformException {
      // Already gone.
    } on MissingPluginException {
      // Ignore.
    }
  }

  Future<void> _close(int id) async {
    try {
      await _method.invokeMethod<void>('close', <String, dynamic>{'id': id});
    } on PlatformException {
      // Already gone.
    } on MissingPluginException {
      // Ignore.
    }
  }

  /// Terminates every live guest process. Called when the UI goes away.
  Future<void> dispose() async {
    final List<int> ids = _sessions.keys.toList(growable: false);
    for (final int id in ids) {
      await _kill(id, 9);
      _sessions[id]?._finish(-1);
      _sessions.remove(id);
    }
    await _subscription?.cancel();
    _subscription = null;
  }
}

/// Human-readable `errno`, which is what a failed `fork`/`execve`/`chmod`
/// actually reports.
String describeErrno(int errno) {
  switch (errno) {
    case -1:
      return 'unknown error';
    case 1: // EPERM
      return 'operation not permitted (EPERM) — SELinux blocked the syscall';
    case 2: // ENOENT
      return 'no such file or directory (ENOENT) — binary or rootfs missing';
    case 8: // ENOEXEC
      return 'exec format error (ENOEXEC) — binary is not an ARM64 executable';
    case 12: // ENOMEM
      return 'out of memory (ENOMEM)';
    case 13: // EACCES
      return 'permission denied (EACCES) — the file is not executable on this device';
    case 20: // ENOTDIR
      return 'not a directory (ENOTDIR)';
    case 22: // EINVAL
      return 'invalid argument (EINVAL)';
    case 26: // ETXTBSY
      return 'text file busy (ETXTBSY)';
    case 28: // ENOSPC
      return 'no space left on device (ENOSPC)';
    case 30: // EROFS
      return 'read-only file system (EROFS)';
    case 38: // ENOSYS
      return 'function not implemented (ENOSYS)';
    default:
      return 'errno $errno';
  }
}
