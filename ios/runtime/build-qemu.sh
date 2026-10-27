#!/bin/bash
# Cross-compile the pinned QEMU as a static archive for the iOS device SDK.
# The archive is linked into the app. It does not use the hypervisor: StikDebug
# makes TCG's translator executable in this process. The link test is an iOS
# executable and does not run on macOS.

set -euo pipefail

runtime_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$runtime_dir/../.." && pwd)
# shellcheck source=sdk.sh
source "$runtime_dir/sdk.sh"
# shellcheck source=build-zstd.sh
# zstd is built by invoking the script, not sourcing it.

jobs=${OMARCHY_RUNTIME_BUILD_JOBS:-$(sysctl -n hw.ncpu)}
cache=${OMARCHY_DOWNLOAD_CACHE:-$root/.build/downloads}
prefix="$root/ios/.build/deps"
out="$root/ios/runtime/out"
src="$root/ios/.build/src"
native_dir="$root/macos"
qemu_commit=$(sed -n 's/^qemu_commit=\([0-9a-f]\{40\}\)$/\1/p' "$native_dir/build-qemu-gpu-runtime.sh")
qemu_sha256=$(sed -n 's/^qemu_sha256=\([0-9a-f]\{64\}\)$/\1/p' "$native_dir/build-qemu-gpu-runtime.sh")
[[ -n $qemu_commit && -n $qemu_sha256 ]] || { echo "build-qemu: cannot read the QEMU pin" >&2; exit 1; }

for tool in clang curl python3 pkg-config cmake ninja meson libtool make; do
  command -v "$tool" >/dev/null || { echo "build-qemu: $tool is required" >&2; exit 1; }
done

mkdir -p "$cache" "$prefix" "$out" "$src"
export PATH="$prefix/bin:$PATH"
export CC=clang CXX=clang++
export CFLAGS="$IOS_CFLAGS" LDFLAGS="$IOS_LDFLAGS"

fetch() {
  local name=$1 url=$2 sha=$3
  if [[ ! -f $cache/$name ]]; then
    curl -fsSL "$url" -o "$cache/$name.partial"
    mv -f "$cache/$name.partial" "$cache/$name"
  fi
  [[ $(shasum -a 256 "$cache/$name" | cut -d' ' -f1) == "$sha" ]] || {
    echo "build-qemu: $name does not match its pin" >&2
    exit 1
  }
}

cross="$src/iphoneos.ini"
cat >"$cross" <<EOF
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'ar'
pkg-config = 'pkg-config'
pkgconfig = 'pkg-config'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$IOS_SDKROOT', '-miphoneos-version-min=$IOS_MIN_VERSION', '-fPIC']
c_link_args = ['-arch', 'arm64', '-isysroot', '$IOS_SDKROOT', '-miphoneos-version-min=$IOS_MIN_VERSION']
cpp_args = ['-arch', 'arm64', '-isysroot', '$IOS_SDKROOT', '-miphoneos-version-min=$IOS_MIN_VERSION', '-fPIC']
cpp_link_args = ['-arch', 'arm64', '-isysroot', '$IOS_SDKROOT', '-miphoneos-version-min=$IOS_MIN_VERSION']
EOF

"$runtime_dir/build-zstd.sh"
# Homebrew pkg-config would otherwise hand QEMU macOS libssh, gcrypt, and X11.
pkg_config_libdir="$root/ios/.build/zstd/lib/pkgconfig:$prefix/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$pkg_config_libdir"
export PKG_CONFIG_PATH="$pkg_config_libdir"
unset PKG_CONFIG_SYSROOT_DIR
pkg-config --exists libzstd || { echo "build-qemu: libzstd was not staged for iOS" >&2; exit 1; }
if pkg-config --exists libssh || pkg-config --exists libgcrypt || pkg-config --exists x11; then
  echo "build-qemu: a host pkg-config package leaked into the iOS build" >&2
  exit 1
fi

if [[ ! -f $prefix/lib/libffi.a ]]; then
  fetch libffi-3.4.6.tar.gz \
    https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz \
    b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e
  rm -rf "$src/libffi-3.4.6"
  tar -xzf "$cache/libffi-3.4.6.tar.gz" -C "$src"
  (
    cd "$src/libffi-3.4.6"
    ./configure --host=aarch64-apple-darwin --build=x86_64-apple-darwin \
      --prefix="$prefix" --disable-shared --enable-static --disable-docs
    # Apple's assembler rejects libffi's CFI expressions. The calls still work
    # without the unwind directives.
    for header in fficonfig.h */fficonfig.h; do
      [[ -f $header ]] || continue
      sed -i '' 's/^#define HAVE_AS_CFI_PSEUDO_OP 1/#undef HAVE_AS_CFI_PSEUDO_OP/' "$header"
    done
    make -j"$jobs"
    make install
  )
fi

if [[ ! -f $prefix/lib/libpcre2-8.a ]]; then
  fetch pcre2-10.44.tar.gz \
    https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz \
    86b9cb0aa3bcb7994faa88018292bc704cdbb708e785f7c74352ff6ea7d3175b
  rm -rf "$src/pcre2-10.44"
  tar -xzf "$cache/pcre2-10.44.tar.gz" -C "$src"
  cmake -G Ninja -S "$src/pcre2-10.44" -B "$src/pcre2-10.44/build" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="$IOS_SDKROOT" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DBUILD_SHARED_LIBS=OFF \
    -DPCRE2_BUILD_PCRE2GREP=OFF \
    -DPCRE2_BUILD_TESTS=OFF \
    -DPCRE2_SUPPORT_JIT=OFF
  ninja -C "$src/pcre2-10.44/build" -j"$jobs"
  ninja -C "$src/pcre2-10.44/build" install
fi

if [[ ! -f $prefix/lib/libglib-2.0.a ]]; then
  fetch glib-2.82.4.tar.xz \
    https://download.gnome.org/sources/glib/2.82/glib-2.82.4.tar.xz \
    37dd0877fe964cd15e9a2710b044a1830fb1bd93652a6d0cb6b8b2dff187c709
  rm -rf "$src/glib-2.82.4"
  tar -xf "$cache/glib-2.82.4.tar.xz" -C "$src"
  meson setup "$src/glib-2.82.4/build" "$src/glib-2.82.4" --cross-file "$cross" \
    --prefix="$prefix" --default-library=static \
    -Dtests=false -Dlibmount=disabled -Dselinux=disabled -Dxattr=false \
    -Dnls=disabled -Dglib_debug=disabled -Dintrospection=disabled -Dlibelf=disabled
  meson compile -C "$src/glib-2.82.4/build" -j"$jobs"
  meson install -C "$src/glib-2.82.4/build"
fi

if [[ ! -f $prefix/lib/libpixman-1.a ]]; then
  fetch pixman-0.44.2.tar.gz \
    https://www.cairographics.org/releases/pixman-0.44.2.tar.gz \
    6349061ce1a338ab6952b92194d1b0377472244208d47ff25bef86fc71973466
  rm -rf "$src/pixman-0.44.2"
  tar -xzf "$cache/pixman-0.44.2.tar.gz" -C "$src"
  meson setup "$src/pixman-0.44.2/build" "$src/pixman-0.44.2" --cross-file "$cross" \
    --prefix="$prefix" --default-library=static \
    -Ddemos=disabled -Dgtk=disabled -Dtests=disabled -Dlibpng=disabled
  meson compile -C "$src/pixman-0.44.2/build" -j"$jobs"
  meson install -C "$src/pixman-0.44.2/build"
fi

if [[ ! -f $prefix/lib/libslirp.a ]]; then
  fetch libslirp-v4.8.0.tar.gz \
    https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.8.0/libslirp-v4.8.0.tar.gz \
    2a98852e65666db313481943e7a1997abff0183bd9bea80caec1b5da89fda28c
  rm -rf "$src/libslirp-v4.8.0"
  tar -xzf "$cache/libslirp-v4.8.0.tar.gz" -C "$src"
  meson setup "$src/libslirp-v4.8.0/build" "$src/libslirp-v4.8.0" --cross-file "$cross" \
    --prefix="$prefix" --default-library=static
  meson compile -C "$src/libslirp-v4.8.0/build" -j"$jobs"
  meson install -C "$src/libslirp-v4.8.0/build"
fi

qemu_archive="qemu-$qemu_commit.tar.gz"
fetch "$qemu_archive" \
  "https://gitlab.com/qemu-project/qemu/-/archive/$qemu_commit/$qemu_archive" \
  "$qemu_sha256"
qemu_src="$src/qemu-$qemu_commit"
if [[ ! -f $qemu_src/.tryomarchy-ios-patched ]]; then
  rm -rf "$qemu_src"
  tar -xzf "$cache/$qemu_archive" -C "$src"
  patch -p1 -d "$qemu_src" <"$runtime_dir/patches/qemu-tryomarchy-ios.patch"
  touch "$qemu_src/.tryomarchy-ios-patched"
fi

clang $IOS_CFLAGS -c "$runtime_dir/jit/jit26.c" -o "$out/jit26-linktest.o"
qemu_build="$src/qemu-ios-build"
qemu_python=
path_python=$(command -v python3 || true)
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 $path_python; do
  [[ -n $candidate && -x $candidate ]] || continue
  if "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
    qemu_python=$candidate
    break
  fi
done
[[ -n $qemu_python ]] || { echo "build-qemu: Python 3.11 or newer is required" >&2; exit 1; }
if [[ ! -f $qemu_build/build.ninja ]]; then
  mkdir -p "$qemu_build"
  (
    cd "$qemu_build"
    "$qemu_src/configure" --python="$qemu_python" --cross-prefix= --host-cc=/usr/bin/clang \
      --extra-cflags="-DCONFIG_TRYOMARCHY_IOS" \
      --extra-ldflags="$out/jit26-linktest.o" \
      --target-list=aarch64-softmmu \
      --disable-werror --disable-docs --disable-tools --disable-guest-agent \
      --disable-plugins --disable-hvf --disable-cocoa --disable-gtk --disable-sdl \
      --disable-opengl --disable-virglrenderer --disable-spice --disable-usb-redir \
      --disable-gnutls --disable-bsd-user --disable-linux-user --disable-coreaudio \
      --disable-libusb --disable-curl --disable-smartcard --disable-capstone \
      --disable-rust --disable-pie \
      --disable-gcrypt --disable-nettle --disable-libssh --disable-dbus-display \
      --disable-fuse --disable-png --disable-vnc-jpeg --disable-xkbcommon \
      --disable-libnfs --disable-libiscsi --disable-auth-pam --disable-bzip2 \
      --disable-lzo --disable-snappy --disable-selinux \
      --enable-tcg --enable-vnc --enable-slirp --enable-zstd \
      --with-coroutine=sigaltstack \
      --prefix="$prefix"
  )
fi
ninja -C "$qemu_build" -j"$jobs" qemu-system-aarch64

# qemu-system-aarch64's last step only stamps an entitlement. The objects are
# on the unsigned binary's link line. Those objects are archived and later
# force-loaded: the app also has a weak tryomarchy_qemu_start, and a normal
# archive search would keep that stub. Static libraries stay searched. Merging
# libstubs_arm.a into the force-loaded archive defines both a real object and
# its stub.
link=$(ninja -C "$qemu_build" -t commands qemu-system-aarch64-unsigned | tail -n 1)
objects=()
archives=()
extra=()
previous=
for token in $link; do
  case $token in
    *.o)
      case $token in
        *jit26*) ;;
        /*) objects+=("$token") ;;
        *) objects+=("$qemu_build/$token") ;;
      esac
      ;;
    *.a)
      case $token in
        /*) archives+=("$token") ;;
        *) archives+=("$qemu_build/$token") ;;
      esac
      ;;
    -l*) extra+=("$token") ;;
    -framework) previous=framework ;;
    *)
      if [[ $previous == framework ]]; then
        extra+=("-framework" "$token")
        previous=
      fi
      ;;
  esac
done
[[ ${#objects[@]} -gt 0 ]] || { echo "build-qemu: the QEMU link line had no objects" >&2; exit 1; }
[[ ${#archives[@]} -gt 0 ]] || { echo "build-qemu: the QEMU link line had no archives" >&2; exit 1; }
parts=$(mktemp -d)
part_index=0
batch=()
flush() {
  [[ ${#batch[@]} -gt 0 ]] || return 0
  libtool -static -o "$parts/part$part_index.a" "${batch[@]}"
  batch=()
  part_index=$((part_index + 1))
}
for object in "${objects[@]}"; do
  batch+=("$object")
  if (( ${#batch[@]} >= 150 )); then flush; fi
done
flush
rm -f "$out/libqemu-system-aarch64.a"
libtool -static -o "$out/libqemu-system-aarch64.a" "$parts"/part*.a
rm -rf "$parts"
symbols=$(mktemp)
# nm exits non-zero when a member has no symbols. The listing is still complete.
nm -gU "$out/libqemu-system-aarch64.a" >"$symbols" || true
if grep -q ' JIT26' "$symbols"; then
  echo "build-qemu: the archive must not define the StikDebug helpers" >&2
  rm -f "$symbols"
  exit 1
fi
if grep -q 'stubs_ram-block' "$symbols"; then
  echo "build-qemu: libstubs must be searched, not merged into the force-loaded archive" >&2
  rm -f "$symbols"
  exit 1
fi
grep -q 'T _tryomarchy_qemu_start' "$symbols" || {
  echo "build-qemu: the archive does not export tryomarchy_qemu_start" >&2
  rm -f "$symbols"
  exit 1
}
rm -f "$symbols"
link_line=()
if (( ${#archives[@]} > 0 )); then
  link_line+=("${archives[@]}")
fi
if (( ${#extra[@]} > 0 )); then
  link_line+=("${extra[@]}")
fi
if (( ${#link_line[@]} > 0 )); then
  printf '%s\n' "${link_line[*]}" >"$out/link.flags"
else
  : >"$out/link.flags"
fi
"$runtime_dir/write-runtime-config.sh"
echo "QEMU archive staged in $out"
echo "The iOS executable link is a compile check. It does not boot a VM on this Mac."
