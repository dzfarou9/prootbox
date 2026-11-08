import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../app_services.dart';
import '../core/logger.dart';
import '../core/settings.dart';
import '../linux/install_progress.dart';
import '../native/pty_bridge.dart';
import '../terminal/terminal_session.dart';
import 'app_theme.dart';
import 'bootstrap_screen.dart';
import 'diagnostics_sheet.dart';
import 'widgets/terminal_key_bar.dart';

/// The interactive terminal: xterm view + PTY bridge + guest key bar.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late final TerminalSession _session;
  late AppSettings _settings;
  String? _banner;

  @override
  void initState() {
    super.initState();
    _settings = widget.services.environment.settings;
    _session = TerminalSession(
      environment: widget.services.environment,
      pty: widget.services.pty,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_launch()));
  }

  @override
  void dispose() {
    unawaited(_session.dispose());
    super.dispose();
  }

  Future<void> _launch() async {
    try {
      await _session.start();
      if (mounted) {
        setState(() => _banner = null);
      }
    } on EnvironmentException catch (error) {
      _showBanner(
        error.hint == null ? error.message : '${error.message}\n${error.hint}',
      );
    } on PtyException catch (error) {
      _showBanner(error.message);
    } catch (error, stackTrace) {
      AppLogger.instance
          .logError('could not start the guest session', error, stackTrace);
      _showBanner('$error');
    }
  }

  void _showBanner(String message) {
    AppLogger.instance.log('banner: $message');
    if (!mounted) {
      return;
    }
    setState(() => _banner = message);
  }

  Future<void> _handleMenu(String value) async {
    switch (value) {
      case 'restart':
        await _launch();
        return;
      case 'shell':
        await _pickShell();
        return;
      case 'font_inc':
        await _setFontSize(_settings.fontSize + 1);
        return;
      case 'font_dec':
        await _setFontSize(_settings.fontSize - 1);
        return;
      case 'paste':
        await _paste();
        return;
      case 'diagnostics':
        await showDiagnosticsSheet(context, widget.services);
        return;
      case 'reset':
        await _resetEnvironment();
        return;
    }
  }

  Future<void> _setFontSize(double size) async {
    final double clamped = size.clamp(9, 24).toDouble();
    if (clamped == _settings.fontSize) {
      return;
    }
    setState(() {
      _settings = _settings.copyWith(fontSize: clamped);
    });
    widget.services.environment.settings.fontSize = clamped;
    await widget.services.settingsStore
        .save(widget.services.environment.settings);
  }

  Future<void> _pickShell() async {
    const List<String> shells = <String>[
      '/bin/sh',
      '/bin/bash',
      '/bin/ash',
      '/bin/dash'
    ];
    final String current =
        _settings.shellPath ?? widget.services.environment.defaultShell();
    final String? selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 18, 18, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Login shell',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            for (final String shell in shells)
              ListTile(
                leading: Icon(
                  shell == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: shell == current ? AppColors.accent : AppColors.muted,
                  size: 20,
                ),
                title: Text(
                  shell,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                ),
                subtitle: shell == '/bin/sh'
                    ? const Text(
                        'Always present (busybox ash on Alpine)',
                        style: TextStyle(color: AppColors.muted, fontSize: 11),
                      )
                    : null,
                onTap: () => Navigator.of(context).pop(shell),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (selected == null || selected == current) {
      return;
    }
    widget.services.environment.settings.shellPath = selected;
    setState(() {
      _settings = _settings.copyWith(shellPath: selected);
    });
    await widget.services.settingsStore
        .save(widget.services.environment.settings);
    await _launch();
  }

  Future<void> _paste() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;
    if (text == null || text.isEmpty) {
      _snack('Clipboard is empty');
      return;
    }
    await _session.sendText(text);
  }

  Future<void> _resetEnvironment() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Reinstall Linux environment?'),
        content: const Text(
          'The container filesystem is deleted and unpacked again from the '
          'bundled archive. Files under /root (your home directory) are kept.',
          style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reinstall'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    await _session.stop();
    if (!mounted) {
      return;
    }

    final ValueNotifier<InstallProgress> progress =
        ValueNotifier<InstallProgress>(
      const InstallProgress(InstallPhase.preparing, 0, 'Starting'),
    );
    final Future<void> dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) =>
          InstallProgressDialog(progress: progress),
    );

    try {
      await widget.services.environment.resetRootfs();
      await widget.services.environment.install(
        onProgress: (InstallProgress value) => progress.value = value,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.logError('reinstall failed', error, stackTrace);
      _showBanner('$error');
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      await dialog;
    }

    await _launch();
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final String? banner = _banner;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(
          children: <Widget>[
            ValueListenableBuilder<bool>(
              valueListenable: _session.running,
              builder: (BuildContext context, bool running, Widget? child) {
                return Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 9),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: running ? AppColors.accent : AppColors.danger,
                  ),
                );
              },
            ),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: _session.title,
                builder: (BuildContext context, String title, Widget? child) {
                  return Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Paste',
            icon: const Icon(Icons.content_paste_go),
            onPressed: () => unawaited(_paste()),
          ),
          IconButton(
            tooltip: 'Restart session',
            icon: const Icon(Icons.restart_alt),
            onPressed: () => unawaited(_launch()),
          ),
          PopupMenuButton<String>(
            tooltip: 'Menu',
            color: AppColors.surfaceAlt,
            onSelected: (String value) => unawaited(_handleMenu(value)),
            itemBuilder: (BuildContext context) =>
                const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'restart',
                child: Text('Restart session'),
              ),
              PopupMenuItem<String>(
                value: 'shell',
                child: Text('Login shell…'),
              ),
              PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'font_inc',
                child: Text('Increase font size'),
              ),
              PopupMenuItem<String>(
                value: 'font_dec',
                child: Text('Decrease font size'),
              ),
              PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'diagnostics',
                child: Text('Diagnostics'),
              ),
              PopupMenuItem<String>(
                value: 'reset',
                child: Text('Reinstall environment'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (banner != null)
            _ErrorBanner(
              message: banner,
              onDismiss: () => setState(() => _banner = null),
              onDiagnostics: () => unawaited(
                showDiagnosticsSheet(context, widget.services),
              ),
            ),
          Expanded(
            child: Container(
              color: AppColors.background,
              child: TerminalView(
                _session.terminal,
                autofocus: true,
                theme: TerminalThemes.defaultTheme,
                textStyle: TerminalStyle(fontSize: _settings.fontSize),
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                backgroundOpacity: 1,
                // Long-press is the natural "paste" gesture in a mobile terminal.
                onSecondaryTapDown: (details, offset) {
                  unawaited(_paste());
                },
              ),
            ),
          ),
          TerminalKeyBar(
            onKey: (String sequence) => unawaited(_session.sendKeys(sequence)),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.message,
    required this.onDismiss,
    required this.onDiagnostics,
  });

  final String message;
  final VoidCallback onDismiss;
  final VoidCallback onDiagnostics;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.error_outline, color: AppColors.danger, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
          TextButton(
            onPressed: onDiagnostics,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('Details', style: TextStyle(fontSize: 12)),
          ),
          IconButton(
            tooltip: 'Dismiss',
            onPressed: onDismiss,
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
