#!/bin/bash
# Build static libzstd for the iOS device SDK and the simulator SDK.
# Device output: ios/.build/zstd/. Simulator output: ios/.build/zstd-simulator/.

set -euo pipefail

runtime_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$runtime_dir/../.." && pwd)
# shellcheck source=sdk.sh
source "$runtime_dir/sdk.sh"

version=1.5.6
sha256=8c29e06cf42aacc1eafc4077ae2ec6c6fcb96a626157e0593d5e82a34fd403c1
cache=${OMARCHY_DOWNLOAD_CACHE:-$root/.build/downloads}
archive="zstd-$version.tar.gz"
url="https://github.com/facebook/zstd/releases/download/v$version/$archive"
jobs=$(sysctl -n hw.ncpu)

mkdir -p "$cache"
if [[ ! -f $cache/$archive ]]; then
  curl -fsSL "$url" -o "$cache/$archive.partial"
  mv -f "$cache/$archive.partial" "$cache/$archive"
fi
[[ $(shasum -a 256 "$cache/$archive" | cut -d' ' -f1) == "$sha256" ]] || {
  echo "build-zstd: the zstd archive does not match its pin" >&2
  exit 1
}

write_pc() {
  local prefix=$1
  mkdir -p "$prefix/lib/pkgconfig"
  cat >"$prefix/lib/pkgconfig/libzstd.pc" <<EOF
prefix=$prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libzstd
Description: Zstandard
Version: $version
Libs: -L\${libdir} -lzstd
Cflags: -I\${includedir}
EOF
  cp "$prefix/lib/pkgconfig/libzstd.pc" "$prefix/lib/pkgconfig/zstd.pc"
}

stage_zstd() {
  local prefix=$1
  local cflags=$2
  mkdir -p "$prefix/lib" "$prefix/include"
  if [[ -f $prefix/lib/libzstd.a && -f $prefix/include/zstd.h ]]; then
    write_pc "$prefix"
    echo "zstd already staged in $prefix"
    return 0
  fi
  local work
  work=$(mktemp -d)
  tar -xzf "$cache/$archive" -C "$work"
  make -C "$work/zstd-$version/lib" libzstd.a -j"$jobs" \
    CC=clang CFLAGS="$cflags" MOREFLAGS="$cflags"
  cp "$work/zstd-$version/lib/libzstd.a" "$prefix/lib/libzstd.a"
  cp "$work/zstd-$version/lib/zstd.h" "$work/zstd-$version/lib/zstd_errors.h" "$prefix/include/"
  rm -rf "$work"
  write_pc "$prefix"
  echo "zstd staged in $prefix"
}

stage_zstd "$root/ios/.build/zstd" "$IOS_CFLAGS"
simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
stage_zstd "$root/ios/.build/zstd-simulator" \
  "-arch arm64 -isysroot ${simulator_sdk} -mios-simulator-version-min=${IOS_MIN_VERSION} -fPIC"
