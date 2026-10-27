#!/bin/bash
# Copy UTM's prebuilt iOS Simulator QEMU into ios/.build/utm/Frameworks.
# The tarball is the Sysroot-ios_simulator-arm64 artifact from utmapp/UTM.
# Install names in that artifact point at the GitHub runner, so they are
# rewritten to @rpath and each library is ad-hoc signed again.

set -euo pipefail

runtime_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$runtime_dir/../.." && pwd)
tarball=$root/ios/.build/utm/sysroot.tgz
extract=$root/ios/.build/utm
libdir=sysroot-ios_simulator-arm64/lib
out=$root/ios/.build/utm/Frameworks

if [[ ! -x ${DEVELOPER_DIR:-}/usr/bin/otool ]]; then
  for app in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -x $app/Contents/Developer/usr/bin/otool ]]; then
      export DEVELOPER_DIR=$app/Contents/Developer
      break
    fi
  done
fi
export PATH="${DEVELOPER_DIR:-}/usr/bin:${PATH}"
command -v otool >/dev/null || { echo "stage-simulator-qemu: otool is required" >&2; exit 1; }

[[ -f $tarball ]] || {
  echo "stage-simulator-qemu: missing $tarball" >&2
  echo "Download the Sysroot-ios_simulator-arm64 artifact from a successful utmapp/UTM Build run." >&2
  exit 1
}

if [[ ! -f $extract/$libdir/libpixman-1.0.dylib && ! -L $extract/$libdir/libpixman-1.0.dylib ]]; then
  echo "stage-simulator-qemu: extracting libraries"
  tar -xzf "$tarball" -C "$extract" "$libdir"
fi

mkdir -p "$out"
work=$(mktemp)
done_names=$(mktemp)
deps=$(mktemp)
trap 'rm -f "$work" "$done_names" "$deps"' EXIT
echo libqemu-aarch64-softmmu.dylib >"$work"

resolve() {
  local name=$1
  local path=$extract/$libdir/$name
  local target base
  [[ -e $path ]] || return 1
  while [[ -L $path ]]; do
    target=$(readlink "$path")
    base=$(basename "$target")
    if [[ $target = /* ]]; then
      path=$target
    else
      path=$extract/$libdir/$base
    fi
    [[ -e $path ]] || return 1
  done
  printf '%s\n' "$path"
}

while [[ -s $work ]]; do
  name=$(head -n 1 "$work")
  tail -n +2 "$work" >"$work.next"
  mv "$work.next" "$work"
  if grep -qx "$name" "$done_names"; then
    continue
  fi
  echo "$name" >>"$done_names"
  if ! path=$(resolve "$name"); then
    echo "stage-simulator-qemu: missing $name in the sysroot" >&2
    exit 1
  fi
  id=$(otool -D "$path" | awk 'NR==2 { print; exit }')
  [[ -n $id ]] || { echo "stage-simulator-qemu: $name has no install id" >&2; exit 1; }
  cp -f "$path" "$out/$(basename "$id")"
  otool -L "$path" | awk 'NR>1 { print $1 }' >"$deps"
  while read -r dep; do
    [[ -n $dep ]] || continue
    case $dep in
      /usr/lib/* | /System/*) continue ;;
    esac
    depbase=$(basename "$dep")
    if [[ ! -e $extract/$libdir/$depbase ]]; then
      case $dep in
        @rpath/* | @loader_path/* | @executable_path/*) continue ;;
      esac
      echo "stage-simulator-qemu: $name needs $dep, which is not in the sysroot lib directory" >&2
      exit 1
    fi
    if grep -qx "$depbase" "$done_names"; then
      continue
    fi
    if grep -qx "$depbase" "$work"; then
      continue
    fi
    echo "$depbase" >>"$work"
  done <"$deps"
done

shopt -s nullglob
for lib in "$out"/*.dylib; do
  base=$(basename "$lib")
  install_name_tool -id "@rpath/$base" "$lib"
  otool -L "$lib" | awk 'NR>1 { print $1 }' >"$deps"
  while read -r dep; do
    [[ -n $dep ]] || continue
    case $dep in
      /usr/lib/* | /System/* | @rpath/* | @loader_path/* | @executable_path/*) continue ;;
    esac
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$lib"
  done <"$deps"
  if ! otool -l "$lib" | grep -q '@loader_path'; then
    install_name_tool -add_rpath @loader_path "$lib"
  fi
  codesign --remove-signature "$lib"
  codesign -s - -f "$lib" >/dev/null
done

leftover=$(otool -L "$out"/*.dylib | awk 'NR>1 { print $1 }' | grep -E '/Users/runner|sysroot-' || true)
if [[ -n $leftover ]]; then
  echo "stage-simulator-qemu: an install name still points outside the app" >&2
  echo "$leftover" >&2
  exit 1
fi
missing=""
while read -r needed; do
  [[ -f $out/$needed ]] || missing="$missing $needed"
done < <(otool -L "$out"/*.dylib | awk '/@rpath\// { print $1 }' | sed 's|@rpath/||' | sort -u)
if [[ -n $missing ]]; then
  echo "stage-simulator-qemu: still missing$missing" >&2
  exit 1
fi

share=$root/ios/.build/utm/qemu-share
rm -rf "$share"
mkdir -p "$share"
tar -xzf "$tarball" -C "$extract" sysroot-ios_simulator-arm64/share/qemu/keymaps
cp -R "$extract/sysroot-ios_simulator-arm64/share/qemu/keymaps" "$share/keymaps"
[[ -f $share/keymaps/en-us ]] || {
  echo "stage-simulator-qemu: the keymap en-us is missing" >&2
  exit 1
}

echo "simulator QEMU staged in $out ($(du -sh "$out" | awk '{ print $1 }'))"
