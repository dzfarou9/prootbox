import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../core/logger.dart';
import '../linux/install_progress.dart';
import 'app_theme.dart';

Future<void> showDiagnosticsSheet(BuildContext context, AppServices services) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (BuildContext context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.88,
      minChildSize: 0.45,
      maxChildSize: 0.96,
      builder: (BuildContext context, ScrollController controller) =>
          _DiagnosticsBody(services: services, controller: controller),
    ),
  );
}

class _DiagnosticsBody extends StatefulWidget {
  const _DiagnosticsBody({required this.services, required this.controller});

  final AppServices services;
  final ScrollController controller;

  @override
  State<_DiagnosticsBody> createState() => _DiagnosticsBodyState();
}

class _DiagnosticsBodyState extends State<_DiagnosticsBody> {
  late Future<EnvironmentStatus> _status =
      widget.services.environment.inspect(refresh: true);

  void _refresh() {
    setState(() {
      _status = widget.services.environment.inspect(refresh: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Diagnostics',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 20),
            ),
            IconButton(
              tooltip: 'Copy report',
              onPressed: _copyReport,
              icon: const Icon(Icons.copy_all, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 4),
        FutureBuilder<EnvironmentStatus>(
          future: _status,
          builder: (BuildContext context,
              AsyncSnapshot<EnvironmentStatus> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final EnvironmentStatus? status = snapshot.data;
            if (status == null) {
              return const Text(
                'Could not inspect the sandbox.',
                style: TextStyle(color: AppColors.danger, fontSize: 13),
              );
            }
            return _StatusReport(status: status);
          },
        ),
        const SizedBox(height: 22),
        const Text(
          'Environment',
          style: TextStyle(
            color: AppColors.text,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 8),
        _KeyValue('App data', widget.services.paths.root),
        _KeyValue('Rootfs', widget.services.paths.rootfsDir.path),
        _KeyValue('Home (guest /root)', widget.services.paths.homeDir.path),
        _KeyValue('PROOT_TMP_DIR', widget.services.paths.prootTmpDir.path),
        _KeyValue(
            'Native library dir', widget.services.device.nativeLibraryDir),
        _KeyValue(
          'Supported ABIs',
          widget.services.device.supportedAbis.join(', '),
        ),
        _KeyValue('Shell', widget.services.environment.defaultShell()),
        const SizedBox(height: 22),
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Runtime log',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                AppLogger.instance.clear();
                setState(() {});
              },
              child: const Text('Clear'),
            ),
          ],
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: SelectableText(
            AppLogger.instance.tail(60),
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 10.5,
              height: 1.45,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _copyReport() async {
    final EnvironmentStatus status =
        await widget.services.environment.inspect(refresh: true);
    final StringBuffer buffer = StringBuffer()
      ..writeln('ProotBox diagnostics')
      ..writeln('generated: ${DateTime.now().toIso8601String()}')
      ..writeln('device: ${widget.services.device.model}')
      ..writeln('sdk: ${widget.services.device.sdkInt}')
      ..writeln('abi: ${widget.services.device.abi}')
      ..writeln('');

    for (final DiagnosticEntry entry in status.diagnostics) {
      buffer.writeln(
          '${entry.ok ? '[ok]  ' : '[!!]  '}${entry.label}: ${entry.value}');
    }

    final EnvironmentManifest? manifest = status.manifest;
    if (manifest != null) {
      buffer
        ..writeln('')
        ..writeln('flavor: ${manifest.flavor}')
        ..writeln('shell: ${manifest.shell}')
        ..writeln('archive: ${manifest.archive}')
        ..writeln('installed: ${manifest.installedAt}')
        ..writeln('files: ${manifest.files}');
    }

    buffer
      ..writeln('')
      ..writeln('--- log ---')
      ..writeln(AppLogger.instance.tail(120));

    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Diagnostics copied to clipboard')),
      );
    }
  }
}

class _StatusReport extends StatelessWidget {
  const _StatusReport({required this.status});

  final EnvironmentStatus status;

  @override
  Widget build(BuildContext context) {
    final Color tone = status.isReady
        ? AppColors.accent
        : (status.hasBlockingProblem ? AppColors.danger : AppColors.warning);
    final String headline = status.isReady
        ? 'Sandbox ready'
        : (status.hasBlockingProblem ? 'Sandbox blocked' : 'Sandbox degraded');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: tone.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                status.isReady
                    ? Icons.check_circle_outline
                    : Icons.warning_amber,
                color: tone,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headline,
                  style: TextStyle(
                    color: tone,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final DiagnosticEntry entry in status.diagnostics)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  margin: const EdgeInsets.only(top: 5),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: entry.ok
                        ? AppColors.accent
                        : (entry.fatal ? AppColors.danger : AppColors.warning),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 118,
                  child: Text(
                    entry.label,
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 11.5),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    entry.value,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
