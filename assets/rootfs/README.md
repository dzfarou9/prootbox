# assets/rootfs

This directory is declared as an asset folder in `pubspec.yaml`, so it must
exist in git — but its content is generated, not committed.

```bash
../../scripts/build-rootfs.sh                  # Alpine minirootfs aarch64
../../scripts/build-rootfs.sh --flavor ubuntu  # Ubuntu Base arm64
```

Produced files:

| File | Purpose |
| --- | --- |
| `rootfs.tar.gz` | the Linux userland the app extracts on first launch |
| `rootfs.json` | provenance: source URL, sha256, size, build date |

Rules the runtime relies on:

* **gzip, not xz** — `dart:io` has a native gzip decoder and Android gives apps
  no `xz` decoder. `rootfs.tar.xz` is detected and rejected with a hint.
* The archive must contain `bin/sh` (a symlink to busybox on Alpine is fine) —
  it is the health check performed after extraction.
* ustar, GNU long-name (`L`/`K`) and pax (`x`/`g`) headers are all supported.
* Modes are preserved: the tar's `mode` field is replayed through
  `Os.chmod`, so `/bin/*` ends up executable inside the container.

`rootfs.tar.gz` and `rootfs.tar.xz` are gitignored.
