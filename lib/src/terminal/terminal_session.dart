import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../core/logger.dart';
import '../linux/linux_environment.dart';
import '../linux/proot_command.dart';
import '../native/pty_bridge.dart';

/// Owns one interactive guest session: the xterm `Terminal`, the PTY and the
/// wiring between them.
class TerminalSession {
  TerminalSession({required this.environment, required this.pty});

  final LinuxEnvironment environment;
  final PtyBridge pty;

  /// The VT100/xterm-256color state machine rendered by `TerminalView`.
  final Terminal terminal = Terminal(maxLines: 30000);

  final ValueNotifier<String> title = ValueNotifier<String>('Terminal');
  final ValueNotifier<bool> running = ValueNotifier<bool>(false);

  PtySession? _session;
  StreamSubscription<String>? _output;
  bool _disposed = false;

  bool get isRunning => running.value;

  Future<void> start() async {
    if (_disposed) {
      return;
    }
    await stop();

    terminal.onOutput = _handleInput;
    terminal.onResize = _handleResize;
    terminal.onTitleChange = _handleTitle;

    final String shell = environment.defaultShell();
    final LaunchSpec spec = await environment.buildLaunchSpec(
      ProotOptions(
        command: <String>[shell, '-l'],
        fakeRoot: environment.settings.fakeRoot,
        link2Symlink: environment.settings.link2Symlink,
        killOnExit: environment.settings.killOnExit,
        disableSeccomp: environment.settings.disableSeccomp,
      ),
    );

    AppLogger.instance.log('launch: ${spec.describe()}');

    final PtySession session = await pty.spawn(
      executable: spec.executable,
      arguments: spec.arguments,
      environment: spec.environment,
      workingDirectory: spec.workingDirectory,
      rows: math.max(12, terminal.viewHeight),
      cols: math.max(24, terminal.viewWidth),
    );

    if (_disposed) {
      await session.kill();
      return;
    }

    _session = session;
    running.value = true;

    _output = session.output.transform(utf8.decoder).listen(
      (String data) {
        if (!_disposed) {
          terminal.write(data);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.instance
            .logError('pty output stream error', error, stackTrace);
      },
    );

    unawaited(session.exitCode.then((int code) => _handleExit(session, code)));
  }

  Future<void> restart() => start();

  Future<void> stop() async {
    final PtySession? session = _session;
    _session = null;
    await _output?.cancel();
    _output = null;
    running.value = false;
    if (session != null && !session.hasExited) {
      // SIGHUP: the shell exits, the PTY closes, the reader thread ends.
      await session.close();
    }
  }

  /// Injects a raw escape sequence (used by the extra-keys bar).
  Future<void> sendKeys(String sequence) async {
    final PtySession? session = _session;
    if (session == null || session.hasExited) {
      return;
    }
    await session.writeString(sequence);
  }

  Future<void> sendText(String text) => sendKeys(text);

  void _handleInput(String data) {
    final PtySession? session = _session;
    if (session == null || _disposed) {
      return;
    }
    unawaited(session.writeString(data));
  }

  void _handleResize(int width, int height, int pixelWidth, int pixelHeight) {
    final PtySession? session = _session;
    if (session == null || _disposed) {
      return;
    }
    // This is what delivers SIGWINCH inside the guest, so `top`, `vim` and
    // OpenCode's TUI re-layout when the keyboard opens.
    unawaited(session.resize(
      rows: math.max(1, height),
      cols: math.max(1, width),
    ));
  }

  void _handleTitle(String value) {
    if (value.trim().isNotEmpty) {
      title.value = value.trim();
    }
  }

  void _handleExit(PtySession session, int code) {
    if (!identical(session, _session)) {
      return;
    }
    running.value = false;
    if (_disposed) {
      return;
    }
    terminal.write(
      '\r\n\x1b[38;5;244m[prootbox] session ended (exit $code) — '
      'use “Restart session” in the menu to start a new shell.\x1b[0m\r\n',
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    terminal.onOutput = null;
    terminal.onResize = null;
    terminal.onTitleChange = null;
    await stop();
    title.dispose();
    running.dispose();
  }
}
