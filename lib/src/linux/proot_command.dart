import '../core/app_paths.dart';
import 'install_progress.dart';

/// A fully resolved command line + environment for `execve`.
class LaunchSpec {
  const LaunchSpec({
    required this.executable,
    required this.arguments,
    required this.environment,
    required this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String workingDirectory;

  String describe() {
    final String args = arguments.map(_quote).join(' ');
    return 'cd $workingDirectory && $executable $args';
  }

  static String _quote(String value) {
    if (value.isEmpty) {
      return "''";
    }
    if (RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(value)) {
      return value;
    }
    return "'${value.replaceAll("'", r"'\''")}'";
  }
}

class ProotOptions {
  const ProotOptions({
    this.command = const <String>['/bin/sh', '-l'],
    this.fakeRoot = true,
    this.link2Symlink = true,
    this.killOnExit = true,
    this.disableSeccomp = true,
    this.guestWorkingDirectory = '/root',
    this.extraBinds = const <String>[],
  });

  /// The guest program and its arguments, e.g. `['/bin/bash', '-l']`.
  final List<String> command;

  /// `-0`: report uid/gid 0 to the guest.
  final bool fakeRoot;

  /// `-L`: emulate hard links with symlinks (npm/yarn installers need it).
  final bool link2Symlink;

  /// `--kill-on-exit`: tear down the guest when PRoot exits.
  final bool killOnExit;

  /// `PROOT_NO_SECCOMP=1`: Android's seccomp filter breaks PRoot's seccomp
  /// accelerator on a number of devices.
  final bool disableSeccomp;

  final String guestWorkingDirectory;

  /// Extra `-b host:guest` bindings.
  final List<String> extraBinds;
}

/// Builds the canonical PRoot invocation:
///
///     proot -0 -L --kill-on-exit -S <rootfs> \
///           -b /dev -b /proc -b /sys \
///           -b <app>/home:/root -b <app>/resolv.conf:/etc/resolv.conf \
///           -w /root /bin/bash -l
///
/// `-S` (stealth) already implies the `/dev`, `/proc`, `/sys` bindings; they
/// are passed explicitly anyway because they document intent and because some
/// PRoot forks only honour the explicit form.
class ProotCommandBuilder {
  ProotCommandBuilder({required this.paths, required this.binaries});

  final AppPaths paths;
  final ProotBinaries binaries;

  LaunchSpec build(ProotOptions options) {
    final String? prootPath = binaries.prootPath;
    if (prootPath == null) {
      throw const EnvironmentException('PRoot binary not found.');
    }

    final List<String> args = <String>[];

    if (options.fakeRoot) {
      args.add('-0');
    }
    if (options.link2Symlink) {
      args.add('-L');
    }
    if (options.killOnExit) {
      args.add('--kill-on-exit');
    }

    // Root filesystem + the host filesystems the guest needs to function.
    args.addAll(<String>['-S', paths.rootfsDir.path]);
    args.addAll(<String>['-b', '/dev', '-b', '/proc', '-b', '/sys']);

    // Persistent home: survives `reset environment`, keeps shell history.
    args.addAll(<String>['-b', '${paths.homeDir.path}:/root']);

    // Android has no /etc/resolv.conf; DNS for `apk add` / `npm install`.
    if (paths.resolvConf.existsSync()) {
      args.addAll(<String>['-b', '${paths.resolvConf.path}:/etc/resolv.conf']);
    }

    for (final String bind in options.extraBinds) {
      args.addAll(<String>['-b', bind]);
    }

    args.addAll(<String>['-w', options.guestWorkingDirectory]);
    args.addAll(options.command);

    return LaunchSpec(
      executable: prootPath,
      arguments: args,
      environment: buildEnvironment(options),
      // Run PRoot from outside the rootfs; PRoot resolves guest paths itself.
      workingDirectory: paths.root,
    );
  }

  Map<String, String> buildEnvironment(ProotOptions options) {
    final String shell =
        options.command.isNotEmpty ? options.command.first : '/bin/sh';
    final Map<String, String> env = <String, String>{
      'HOME': '/root',
      'USER': 'root',
      'LOGNAME': 'root',
      'SHELL': shell,
      'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'TERM': 'xterm-256color',
      'COLORTERM': 'truecolor',
      'LANG': 'C.UTF-8',
      'LC_ALL': 'C.UTF-8',
      'TMPDIR': '/tmp',
      'PWD': options.guestWorkingDirectory,
      'PROOTBOX': '1',
      // PRoot must not try /tmp (does not exist for an Android app).
      'PROOT_TMP_DIR': paths.prootTmpDir.path,
    };

    if (options.disableSeccomp) {
      env['PROOT_NO_SECCOMP'] = '1';
    }

    // THE critical one: point PRoot at a loader that lives in
    // nativeLibraryDir. Guest execve() is then performed by the loader
    // (mmap + PROT_EXEC) instead of the kernel, which Android 10+ forbids for
    // app-writable storage.
    final String? loader = binaries.loaderPath;
    if (loader != null) {
      env['PROOT_LOADER'] = loader;
    }

    return env;
  }
}
