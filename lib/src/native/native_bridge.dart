import 'dart:math' as math;

import 'package:flutter/services.dart';

/// Static information about the host process/device, resolved once by Kotlin.
class DeviceInfo {
  const DeviceInfo({
    required this.nativeLibraryDir,
    required this.packageName,
    required this.abi,
    required this.supportedAbis,
    required this.sdkInt,
    required this.model,
  });

  /// `/data/app/~~xxxx/<package>-xxxx/lib/arm64` — the *only* directory on
  /// Android 10+ whose files may be `execve`d by an app (SELinux
  /// `apk_data_file`). PRoot and its syscall loader are executed from here.
  final String nativeLibraryDir;

  final String packageName;

  /// Primary ABI, e.g. `arm64-v8a`.
  final String abi;

  final List<String> supportedAbis;
  final int sdkInt;
  final String model;

  bool get isArm64 => abi == 'arm64-v8a' || supportedAbis.contains('arm64-v8a');

  Map<String, dynamic> toJson() => <String, dynamic>{
        'nativeLibraryDir': nativeLibraryDir,
        'packageName': packageName,
        'abi': abi,
        'supportedAbis': supportedAbis,
        'sdkInt': sdkInt,
        'model': model,
      };
}

/// A single `chmod` request. Dart has no `chmod`, so extraction hands the
/// tar-derived modes to Kotlin, which calls `android.system.Os.chmod`.
class FileModeEntry {
  const FileModeEntry(this.path, this.mode);

  final String path;

  /// POSIX mode, e.g. `0x1ED` for 0755.
  final int mode;

  List<Object> toJson() => <Object>[path, mode];
}

/// Bridge to `NativeSupportHandler.kt`.
class NativeBridge {
  NativeBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('prootbox/native');

  final MethodChannel _channel;

  DeviceInfo? _deviceInfo;

  Future<DeviceInfo> deviceInfo() async {
    final DeviceInfo? cached = _deviceInfo;
    if (cached != null) {
      return cached;
    }
    final Map<String, dynamic>? raw =
        await _channel.invokeMapMethod<String, dynamic>('deviceInfo');
    if (raw == null) {
      throw const NativeBridgeException(
          'Kotlin bridge returned no device info');
    }
    final Object? abis = raw['supportedAbis'];
    final DeviceInfo info = DeviceInfo(
      nativeLibraryDir: raw['nativeLibraryDir'] as String? ?? '',
      packageName: raw['packageName'] as String? ?? '',
      abi: raw['abi'] as String? ?? '',
      supportedAbis: abis is List
          ? abis.map((Object? e) => '$e').toList(growable: false)
          : const <String>[],
      sdkInt: (raw['sdkInt'] as num?)?.toInt() ?? 0,
      model: raw['model'] as String? ?? 'unknown',
    );
    _deviceInfo = info;
    return info;
  }

  /// True when `path` exists and the process has the execute bit set (`X_OK`).
  ///
  /// This is the single most useful diagnostic on Android: a proot binary that
  /// exists but is not executable produces a confusing "shell not running"
  /// failure instead of a clear error.
  Future<bool> isExecutable(String path) async {
    final bool? result = await _channel
        .invokeMethod<bool>('isExecutable', <String, dynamic>{'path': path});
    return result ?? false;
  }

  Future<bool> exists(String path) async {
    final bool? result = await _channel
        .invokeMethod<bool>('exists', <String, dynamic>{'path': path});
    return result ?? false;
  }

  /// Applies POSIX modes in chunks so a large rootfs (Ubuntu: ~10k entries)
  /// never produces a single oversized platform-channel message.
  Future<void> applyFileModes(List<FileModeEntry> entries) async {
    const int chunkSize = 400;
    for (int start = 0; start < entries.length; start += chunkSize) {
      final int end = math.min(start + chunkSize, entries.length);
      await _channel.invokeMethod<void>('chmod', <String, dynamic>{
        'entries': <List<Object>>[
          for (final FileModeEntry entry in entries.sublist(start, end))
            entry.toJson(),
        ],
      });
    }
  }
}

class NativeBridgeException implements Exception {
  const NativeBridgeException(this.message);

  final String message;

  @override
  String toString() => 'NativeBridgeException: $message';
}
