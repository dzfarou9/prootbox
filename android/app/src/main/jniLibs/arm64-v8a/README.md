# jniLibs/arm64-v8a

Generated payload — nothing here is committed.

```bash
../../../../../scripts/build-proot.sh
```

| File | Real type | Purpose |
| --- | --- | --- |
| `libproot.so` | PRoot executable (ELF, not a shared object) | the sandbox tracer |
| `libproot-loader.so` | PRoot's loader stub | `PROOT_LOADER`; maps guest ELFs so Android's W^X never sees a guest `execve` |
| `libproot-loader32.so` | 32-bit loader (optional) | only needed for 32-bit guests |

Why executables live in a `jniLibs` directory: the Android installer extracts
`lib/**/*.so` into `ApplicationInfo.nativeLibraryDir`, which carries the
`apk_data_file` SELinux label — the one label from which an app may execute.
App-writable storage (`app_data_file`) may never be executed on Android 10+.

This requires legacy native-library packaging, which is enabled in
`android/app/build.gradle`:

```groovy
packagingOptions {
    jniLibs { useLegacyPackaging = true }
}
```

Do not rename these files: the runtime expects `libproot.so` and
`libproot-loader.so` and the installer only extracts files matching `lib*.so`.
