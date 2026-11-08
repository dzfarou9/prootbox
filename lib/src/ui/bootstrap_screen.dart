import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../core/logger.dart';
import '../linux/install_progress.dart';
import 'app_theme.dart';
import 'diagnostics_sheet.dart';
import 'terminal_screen.dart';

/// First screen: verifies the sandbox, extracts the rootfs on first launch and
/// then hands over to the terminal.
class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<BootstrapScreen> {
  InstallProgress _progress = const InstallProgress(
    InstallPhase.preparing,
    0,
    'Checking sandbox state',
  );
  EnvironmentException? _error;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (_running) {
      return;
    }
    setState(() {
      _running = true;
      _error = null;
    });

    try {
      EnvironmentStatus status =
          await widget.services.environment.inspect(refresh: true);

      if (!status.rootfsInstalled) {
        await widget.services.environment.install(
          onProgress: (InstallProgress progress) {
            if (mounted) {
              setState(() => _progress = progress);
            }
          },
        );
        status = await widget.services.environment.inspect(refresh: true);
      }

      if (!status.isReady) {
        throw EnvironmentException(
          status.describeBlockingProblem(),
          hint: status.describeHint(widget.services.device.sdkInt),
        );
      }

      if (!mounted) {
        return;
      }
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              TerminalScreen(services: widget.services),
        ),
      );
    } on EnvironmentException catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
      AppLogger.instance.log('bootstrap blocked: ${error.message}');
    } catch (error, stackTrace) {
      AppLogger.instance.logError('bootstrap failed', error, stackTrace);
      if (mounted) {
        setState(() {
          _error = EnvironmentException(
            '$error',
            hint: 'Open Diagnostics for the extraction log.',
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final EnvironmentException? error = _error;
    final double fraction = _progress.fraction.clamp(0.0, 1.0).toDouble();

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const _LogoMark(),
                  const SizedBox(height: 22),
                  const Text(
                    'PROOTBOX',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'PRoot Linux sandbox · ARM64 · no root required',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted, fontSize: 13),
                  ),
                  const SizedBox(height: 34),
                  if (error == null)
                    _ProgressPanel(progress: _progress, fraction: fraction)
                  else
                    _ErrorPanel(error: error),
                  const SizedBox(height: 20),
                  if (error != null)
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 10,
                      children: <Widget>[
                        FilledButton(
                          onPressed: _running ? null : _run,
                          child: const Text('Retry'),
                        ),
                        OutlinedButton(
                          onPressed: () =>
                              showDiagnosticsSheet(context, widget.services),
                          child: const Text('Diagnostics'),
                        ),
                      ],
                    ),
                  const SizedBox(height: 14),
                  Text(
                    '${widget.services.device.model} · API ${widget.services.device.sdkInt} · ${widget.services.device.abi}',
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({required this.progress, required this.fraction});

  final InstallProgress progress;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                progress.phase.label,
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '${(fraction * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: AppColors.accent, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction <= 0 ? null : fraction,
            minHeight: 6,
            backgroundColor: AppColors.surfaceAlt,
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          progress.message,
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'The Linux userland is unpacked into the app\'s private storage on '
          'first launch. Nothing is installed system-wide.',
          style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.5),
        ),
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.error});

  final EnvironmentException error;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.error_outline, color: AppColors.danger, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sandbox unavailable',
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            error.message,
            style: const TextStyle(
                color: AppColors.text, fontSize: 13, height: 1.5),
          ),
          if (error.hint != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              error.hint!,
              style: const TextStyle(
                  color: AppColors.muted, fontSize: 12, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}

class _LogoMark extends StatelessWidget {
  const _LogoMark();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppColors.border),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: AppColors.accent.withValues(alpha: 0.12),
              blurRadius: 28,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Center(
          child: Text(
            '>_',
            style: TextStyle(
              color: AppColors.accent,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              fontFamily: 'monospace',
              letterSpacing: -2,
            ),
          ),
        ),
      ),
    );
  }
}

/// Blocking progress dialog reused when the container is reinstalled.
class InstallProgressDialog extends StatelessWidget {
  const InstallProgressDialog({super.key, required this.progress});

  final ValueListenable<InstallProgress> progress;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Reinstalling Linux environment'),
        content: ValueListenableBuilder<InstallProgress>(
          valueListenable: progress,
          builder:
              (BuildContext context, InstallProgress value, Widget? child) {
            final double fraction = value.fraction.clamp(0.0, 1.0).toDouble();
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fraction <= 0 ? null : fraction,
                    minHeight: 6,
                    backgroundColor: AppColors.surfaceAlt,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(AppColors.accent),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${value.phase.label} · ${(fraction * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: AppColors.text, fontSize: 12),
                ),
                const SizedBox(height: 6),
                Text(
                  value.message,
                  style: const TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Shown when even the Flutter <-> Kotlin bridge could not be initialised
/// (e.g. the app was launched on an unsupported platform).
class StartupErrorScreen extends StatelessWidget {
  const StartupErrorScreen({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(Icons.memory, color: AppColors.danger, size: 40),
                const SizedBox(height: 16),
                const Text(
                  'Native bridge unavailable',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
