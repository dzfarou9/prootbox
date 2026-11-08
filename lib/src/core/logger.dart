import 'dart:collection';
import 'dart:io';

/// A tiny in-memory + on-disk log used by the in-app diagnostics sheet.
///
/// The terminal itself is the real debugging surface, but when PRoot fails to
/// start there is no terminal yet — so bootstrap/extraction problems are
/// recorded here and shown to the user (and can be copied out).
class AppLogger {
  AppLogger._();

  static final AppLogger instance = AppLogger._();

  static const int _maxEntries = 500;

  final Queue<String> _entries = Queue<String>();
  File? _file;

  List<String> get entries => List<String>.unmodifiable(_entries);

  void attach(File file) {
    _file = file;
    try {
      final Directory parent = file.parent;
      if (!parent.existsSync()) {
        parent.createSync(recursive: true);
      }
    } catch (_) {
      // Logging must never break startup.
    }
  }

  void log(String message) {
    final String line = '${DateTime.now().toIso8601String()} $message';
    _entries.addLast(line);
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    final File? file = _file;
    if (file != null) {
      try {
        file.writeAsStringSync('$line\n', mode: FileMode.append);
      } catch (_) {
        // Ignore: the device may be out of space, that is not fatal here.
      }
    }
  }

  void logError(String message, [Object? error, StackTrace? stackTrace]) {
    log('ERROR $message${error == null ? '' : ': $error'}');
    if (stackTrace != null) {
      for (final String line in stackTrace.toString().split('\n').take(12)) {
        if (line.trim().isEmpty) {
          continue;
        }
        log('  $line');
      }
    }
  }

  String tail([int lines = 40]) {
    final List<String> all = _entries.toList(growable: false);
    final int start = all.length > lines ? all.length - lines : 0;
    return all.sublist(start).join('\n');
  }

  void clear() => _entries.clear();
}
