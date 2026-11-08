import 'dart:io';
import 'dart:typed_data';

import '../native/native_bridge.dart';

/// Result of a completed extraction.
class TarExtractionResult {
  const TarExtractionResult({
    required this.files,
    required this.directories,
    required this.symlinks,
    required this.hardlinks,
    required this.skipped,
    required this.modes,
  });

  final int files;
  final int directories;
  final int symlinks;
  final int hardlinks;
  final int skipped;

  /// Every extracted path paired with the POSIX mode recorded in the archive.
  /// Applied afterwards through Kotlin, because Dart has no `chmod`.
  final List<FileModeEntry> modes;
}

class TarProgress {
  const TarProgress({
    required this.bytesProcessed,
    required this.totalBytes,
    required this.entries,
  });

  final int bytesProcessed;
  final int totalBytes;
  final int entries;

  double get fraction {
    if (totalBytes <= 0) {
      return 0;
    }
    final double value = bytesProcessed / totalBytes;
    return value < 0 ? 0 : (value > 1 ? 1 : value);
  }
}

/// A minimal, dependency-free POSIX/ustar tar extractor.
///
/// Why hand-written instead of a package: the container's userland is only
/// correct if symlinks, hardlinks, directories and *permission bits* survive
/// extraction. Those are exactly the parts that generic archive packages
/// abstract away, and `dart:io` already has a streaming gzip decoder, so the
/// only missing piece was 512-byte header parsing.
///
/// Supported: ustar, GNU long names (`L`/`K`), pax headers (`x`/`g`) — Debian
/// and Alpine tarballs use all three.
class TarExtractor {
  TarExtractor({required this.destination});

  final Directory destination;

  int _files = 0;
  int _dirs = 0;
  int _symlinks = 0;
  int _hardlinks = 0;
  int _skipped = 0;
  int _entries = 0;
  int _lastReportMs = 0;

  final List<FileModeEntry> _modes = <FileModeEntry>[];

  Future<TarExtractionResult> extract(
    File archive, {
    void Function(TarProgress progress)? onProgress,
  }) async {
    final RandomAccessFile raf = await archive.open();
    final int totalBytes = await raf.length();
    String? pendingLongName;
    String? pendingLongLink;
    Map<String, String> pendingPax = <String, String>{};

    try {
      while (true) {
        final int headerStart = await raf.position();
        if (headerStart + 512 > totalBytes) {
          break;
        }
        final Uint8List headerBytes = await _readExact(raf, 512);
        if (headerBytes.length < 512 || _isZeroBlock(headerBytes)) {
          break;
        }

        final TarHeader header = TarHeader.parse(headerBytes);
        final int size = header.size;

        // Metadata records: consume payload, keep state, continue.
        if (header.typeFlag == 'x' || header.typeFlag == 'g') {
          final Uint8List payload = await _readExact(raf, size);
          pendingPax = <String, String>{...pendingPax, ..._parsePax(payload)};
          await raf.setPosition(headerStart + 512 + size + _padding(size));
          continue;
        }
        if (header.typeFlag == 'L') {
          pendingLongName = _cString(await _readExact(raf, size));
          await raf.setPosition(headerStart + 512 + size + _padding(size));
          continue;
        }
        if (header.typeFlag == 'K') {
          pendingLongLink = _cString(await _readExact(raf, size));
          await raf.setPosition(headerStart + 512 + size + _padding(size));
          continue;
        }

        String name = header.prefix.isEmpty
            ? header.name
            : '${header.prefix}/${header.name}';
        if (pendingPax['path'] != null) {
          name = pendingPax['path']!;
        }
        if (pendingLongName != null) {
          name = pendingLongName;
        }

        String linkName = header.linkName;
        if (pendingPax['linkpath'] != null) {
          linkName = pendingPax['linkpath']!;
        }
        if (pendingLongLink != null) {
          linkName = pendingLongLink;
        }

        pendingLongName = null;
        pendingLongLink = null;
        pendingPax = <String, String>{};

        final String? relative = _sanitize(name);
        if (relative == null) {
          _skipped++;
          await raf.setPosition(headerStart + 512 + size + _padding(size));
          continue;
        }

        final String targetPath = '${destination.path}/$relative';

        switch (header.typeFlag) {
          case '5': // directory
            await Directory(targetPath).create(recursive: true);
            _dirs++;
            _addMode(targetPath, header.mode);
          case '2': // symbolic link
            await _createSymlink(targetPath, linkName);
            _symlinks++;
          case '1': // hard link
            await _createHardLink(targetPath, linkName);
            _hardlinks++;
          case '0':
          case '\u0000':
          case '7': // regular file (7 = contiguous)
            final Uint8List content = await _readExact(raf, size);
            await File(targetPath).parent.create(recursive: true);
            await File(targetPath).writeAsBytes(content, flush: false);
            _files++;
            _addMode(targetPath, header.mode);
          default:
            _skipped++;
        }

        _entries++;
        await raf.setPosition(headerStart + 512 + size + _padding(size));

        if (onProgress != null) {
          final int now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastReportMs > 90) {
            _lastReportMs = now;
            onProgress(TarProgress(
              bytesProcessed: await raf.position(),
              totalBytes: totalBytes,
              entries: _entries,
            ));
          }
        }
      }
    } finally {
      await raf.close();
    }

    onProgress?.call(TarProgress(
      bytesProcessed: totalBytes,
      totalBytes: totalBytes,
      entries: _entries,
    ));

    return TarExtractionResult(
      files: _files,
      directories: _dirs,
      symlinks: _symlinks,
      hardlinks: _hardlinks,
      skipped: _skipped,
      modes: _modes,
    );
  }

  void _addMode(String path, int mode) {
    // Only the permission bits matter; setuid/ownership cannot be honoured by
    // an unprivileged app and PRoot fakes root anyway.
    final int permissions = mode & 0xFFF;
    if (permissions == 0) {
      return;
    }
    _modes.add(FileModeEntry(path, permissions));
  }

  Future<void> _createSymlink(String path, String linkName) async {
    if (linkName.isEmpty) {
      _skipped++;
      return;
    }
    final FileSystemEntityType existing =
        await FileSystemEntity.type(path, followLinks: false);
    if (existing == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (existing != FileSystemEntityType.notFound) {
      await File(path).delete();
    }
    await File(path).parent.create(recursive: true);
    try {
      await Link(path).create(linkName);
    } on FileSystemException {
      // Some filesystems refuse symlinks; a copy keeps the rootfs usable.
      _skipped++;
    }
  }

  Future<void> _createHardLink(String path, String linkName) async {
    final String? relative = _sanitize(linkName);
    if (relative == null) {
      _skipped++;
      return;
    }
    final File source = File('${destination.path}/$relative');
    if (!await source.exists()) {
      _skipped++;
      return;
    }
    await File(path).parent.create(recursive: true);
    await source.copy(path);
  }

  Future<Uint8List> _readExact(RandomAccessFile raf, int length) async {
    if (length <= 0) {
      return Uint8List(0);
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    int remaining = length;
    while (remaining > 0) {
      final Uint8List chunk = await raf.read(remaining);
      if (chunk.isEmpty) {
        break;
      }
      builder.add(chunk);
      remaining -= chunk.length;
    }
    return builder.takeBytes();
  }

  static int _padding(int size) => (512 - (size % 512)) % 512;

  static bool _isZeroBlock(Uint8List block) {
    for (int i = 0; i < block.length; i++) {
      if (block[i] != 0) {
        return false;
      }
    }
    return true;
  }

  static String _cString(Uint8List bytes) {
    int end = bytes.length;
    for (int i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0) {
        end = i;
        break;
      }
    }
    return String.fromCharCodes(bytes.sublist(0, end)).trim();
  }

  /// Rejects absolute paths and `..` traversal, strips `./` prefixes.
  static String? _sanitize(String raw) {
    final List<String> parts = <String>[];
    for (final String part in raw.replaceAll('\\', '/').split('/')) {
      if (part.isEmpty || part == '.') {
        continue;
      }
      if (part == '..') {
        return null;
      }
      parts.add(part);
    }
    if (parts.isEmpty) {
      return null;
    }
    return parts.join('/');
  }

  static Map<String, String> _parsePax(Uint8List payload) {
    final Map<String, String> result = <String, String>{};
    final String text = String.fromCharCodes(payload);
    int index = 0;
    while (index < text.length) {
      final int space = text.indexOf(' ', index);
      if (space < 0) {
        break;
      }
      final int? length = int.tryParse(text.substring(index, space).trim());
      if (length == null || length <= 0) {
        break;
      }
      final int end = index + length;
      if (end > text.length || end <= space) {
        break;
      }
      final String record = text.substring(space + 1, end).trimRight();
      final int equals = record.indexOf('=');
      if (equals > 0) {
        result[record.substring(0, equals)] = record.substring(equals + 1);
      }
      index = end;
    }
    return result;
  }
}

/// One 512-byte ustar header.
class TarHeader {
  const TarHeader({
    required this.name,
    required this.mode,
    required this.size,
    required this.typeFlag,
    required this.linkName,
    required this.prefix,
  });

  final String name;
  final int mode;
  final int size;
  final String typeFlag;
  final String linkName;
  final String prefix;

  factory TarHeader.parse(Uint8List block) {
    return TarHeader(
      name: _field(block, 0, 100),
      mode: _octal(block, 100, 8),
      size: _size(block, 124, 12),
      typeFlag: String.fromCharCode(block[156]),
      linkName: _field(block, 157, 100),
      prefix: _field(block, 345, 155),
    );
  }

  static String _field(Uint8List block, int offset, int length) {
    final Uint8List slice =
        Uint8List.sublistView(block, offset, offset + length);
    int end = slice.length;
    for (int i = 0; i < slice.length; i++) {
      if (slice[i] == 0) {
        end = i;
        break;
      }
    }
    return String.fromCharCodes(slice.sublist(0, end)).trim();
  }

  static int _octal(Uint8List block, int offset, int length) {
    final String text = _field(block, offset, length);
    return int.tryParse(text, radix: 8) ?? 0;
  }

  /// Size may be octal or, for files > 8 GiB, GNU base-256.
  static int _size(Uint8List block, int offset, int length) {
    if (block[offset] & 0x80 != 0) {
      int value = 0;
      for (int i = offset + 1; i < offset + length; i++) {
        value = (value << 8) | block[i];
      }
      return value;
    }
    return _octal(block, offset, length);
  }
}
