import 'package:flutter/material.dart';

import '../app_theme.dart';

class TerminalKeySpec {
  const TerminalKeySpec(this.label, this.sequence, {this.tooltip});

  final String label;

  /// Raw bytes written straight to the PTY master. The guest's line editor
  /// (readline / busybox ash) interprets them, exactly like a hardware
  /// keyboard would.
  final String sequence;

  final String? tooltip;
}

/// Soft-keyboard companion: the control characters and arrows a phone keyboard
/// cannot produce but every CLI tool needs.
class TerminalKeyBar extends StatelessWidget {
  const TerminalKeyBar({super.key, required this.onKey});

  final void Function(String sequence) onKey;

  static const List<TerminalKeySpec> keys = <TerminalKeySpec>[
    TerminalKeySpec('ESC', '\x1b', tooltip: 'Escape'),
    TerminalKeySpec('TAB', '\t', tooltip: 'Tab / completion'),
    TerminalKeySpec('^C', '\x03', tooltip: 'Interrupt (SIGINT)'),
    TerminalKeySpec('^D', '\x04', tooltip: 'End of input / logout'),
    TerminalKeySpec('^Z', '\x1a', tooltip: 'Suspend (SIGTSTP)'),
    TerminalKeySpec('^L', '\x0c', tooltip: 'Clear screen'),
    TerminalKeySpec('^R', '\x12', tooltip: 'Reverse history search'),
    TerminalKeySpec('←', '\x1b[D', tooltip: 'Left'),
    TerminalKeySpec('↑', '\x1b[A', tooltip: 'History back'),
    TerminalKeySpec('↓', '\x1b[B', tooltip: 'History forward'),
    TerminalKeySpec('→', '\x1b[C', tooltip: 'Right'),
    TerminalKeySpec('HOME', '\x1b[H', tooltip: 'Home'),
    TerminalKeySpec('END', '\x1b[F', tooltip: 'End'),
    TerminalKeySpec('|', '|'),
    TerminalKeySpec('~', '~'),
    TerminalKeySpec('/', '/'),
    TerminalKeySpec('-', '-'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SizedBox(
        height: 46,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          itemCount: keys.length,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(width: 6),
          itemBuilder: (BuildContext context, int index) {
            final TerminalKeySpec key = keys[index];
            return Tooltip(
              message: key.tooltip ?? key.label,
              child: Material(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onKey(key.sequence),
                  child: Container(
                    alignment: Alignment.center,
                    constraints: const BoxConstraints(minWidth: 44),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      key.label,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
