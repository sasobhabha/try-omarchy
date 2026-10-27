#!/bin/bash
# Common compiler setup for the iOS device runtime. Source this; do not execute it.

if [[ -z ${IOS_SDKROOT:-} ]]; then
  if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    # /usr/bin/xcrun is a shim. The app bundle ships xcodebuild, not xcrun,
    # and the shim only sees the iOS SDK after DEVELOPER_DIR points at Xcode.
    for app in /Applications/Xcode.app /Applications/Xcode-beta.app; do
      if [[ -x $app/Contents/Developer/usr/bin/xcodebuild ]]; then
        export DEVELOPER_DIR=$app/Contents/Developer
        break
      fi
    done
  fi
  IOS_SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
fi
if [[ -z ${IOS_SDKROOT:-} ]]; then
  echo "sdk.sh: the iOS SDK was not found. Install Xcode." >&2
  return 1 2>/dev/null || exit 1
fi
IOS_MIN_VERSION=17.4
IOS_CFLAGS="-arch arm64 -isysroot ${IOS_SDKROOT} -miphoneos-version-min=${IOS_MIN_VERSION} -fPIC"
IOS_LDFLAGS="-arch arm64 -isysroot ${IOS_SDKROOT} -miphoneos-version-min=${IOS_MIN_VERSION}"
