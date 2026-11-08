import 'core/app_paths.dart';
import 'core/logger.dart';
import 'core/settings.dart';
import 'linux/linux_environment.dart';
import 'native/native_bridge.dart';
import 'native/pty_bridge.dart';

/// Everything the app needs, resolved once at startup and passed down.
class AppServices {
  AppServices({
    required this.paths,
    required this.native,
    required this.device,
    required this.pty,
    required this.settings,
    required this.settingsStore,
    required this.environment,
  });

  final AppPaths paths;
  final NativeBridge native;
  final DeviceInfo device;
  final PtyBridge pty;
  final AppSettings settings;
  final SettingsStore settingsStore;
  final LinuxEnvironment environment;

  static Future<AppServices> bootstrap() async {
    final AppLogger logger = AppLogger.instance;
    final AppPaths paths = await AppPaths.resolve();
    await paths.ensureLayout();
    logger.attach(paths.logFile);
    logger.log('bootstrap: root=${paths.root}');

    final NativeBridge native = NativeBridge();
    final DeviceInfo device = await native.deviceInfo();
    logger.log(
      'device: ${device.model} api=${device.sdkInt} abi=${device.abi} '
      'nativeLibraryDir=${device.nativeLibraryDir}',
    );

    final SettingsStore settingsStore = SettingsStore(paths.settingsFile);
    final AppSettings settings = await settingsStore.load();

    final LinuxEnvironment environment = LinuxEnvironment(
      paths: paths,
      native: native,
      device: device,
      settings: settings,
    );

    return AppServices(
      paths: paths,
      native: native,
      device: device,
      pty: PtyBridge(),
      settings: settings,
      settingsStore: settingsStore,
      environment: environment,
    );
  }
}
