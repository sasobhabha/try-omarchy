#!/bin/bash
# Point the Xcode project at whatever of zstd and QEMU has been built.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
ios="$root/ios"
config="$ios/Config/Runtime.local.xcconfig"
zstd="$ios/.build/zstd"
archive="$ios/runtime/out/libqemu-system-aarch64.a"
flags="$ios/runtime/out/link.flags"

has_zstd=0
headers=
libs=
ldflags=
if [[ -f $zstd/lib/libzstd.a && -f $zstd/include/zstd.h ]]; then
  has_zstd=1
  headers="$zstd/include"
  libs="$zstd/lib"
  # Once the runtime exists, link.flags names libzstd.a. Passing -lzstd as
  # well defines every zstd symbol twice. The factory decoder still needs
  # libzstd when the archive has not been built.
  if [[ ! -f $archive ]]; then
    ldflags="-lzstd"
  fi
fi
if [[ -f $archive ]]; then
  # Force-load the object archive. A normal search would leave the app's weak
  # tryomarchy_qemu_start in place and never pull QEMU. link.flags lists the
  # static libraries from the unsigned link, including libstubs, and those are
  # searched normally.
  ldflags="$ldflags -Wl,-force_load,$archive"
  if [[ -f $flags ]]; then
    ldflags="$ldflags $(<"$flags")"
  fi
fi

mkdir -p "$(dirname "$config")"
cat >"$config" <<EOF
TRYOMARCHY_HAS_ZSTD = $has_zstd
TRYOMARCHY_ZSTD_HEADERS = $headers
TRYOMARCHY_ZSTD_LIBS = $libs
TRYOMARCHY_EXTRA_LDFLAGS = $ldflags
EOF
