# assets/proot (optional)

Optional **legacy fallback** for the PRoot binary.

The primary path is `jniLibs/arm64-v8a/libproot.so`, executed from
`ApplicationInfo.nativeLibraryDir` — the only location Android 10+ allows an app
to execute. This directory exists for the case where that path is unusable
(e.g. a build with `targetSdk <= 28`, or an OEM image that refuses execution
from the native library directory).

If you place files here:

```
assets/proot/proot-aarch64            PRoot binary
assets/proot/proot-loader-aarch64     PRoot's syscall loader
```

`LinuxEnvironment.resolveBinaries()` copies them to
`app_flutter/bin/{proot,proot-loader}`, applies `chmod 0755` through Kotlin and
uses them only when the native-library copy is missing or not executable.

Note that with `targetSdk >= 29` these copies are **not executable** by design
of the platform (W^X); Diagnostic will say so instead of failing silently.

Files in this directory are gitignored.
