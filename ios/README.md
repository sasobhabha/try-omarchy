# iOS app

This directory is the on-device shell: a SwiftUI app, the factory download, and an in-process QEMU TCG runtime made executable by StikDebug. The design is in [docs/ios.md](../docs/ios.md). What a person does on a device is in [the manual](../manual/ios.md).

```sh
make test-ios    # contracts on the Mac: manifest, download, boot arguments, VNC
make ios-app     # unsigned iOS compile, with QEMU stubs if the runtime is absent
make ios-runtime # cross-compile the pinned QEMU into ios/runtime/out
make ios         # runtime, firmware, and the unsigned app
make ios-simulator-qemu  # UTM's prebuilt QEMU for the iPhone Simulator
```

`make ios-app` needs [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and Xcode's iOS SDK. It does not sign. If the active developer directory is the command line tools, the build uses `/Applications/Xcode.app` or `Xcode-beta.app`. Open `ios/TryOmarchy.xcodeproj` in Xcode, choose a development team, and install it on a device that has Developer Mode, StikDebug, and LocalDevVPN.

`make ios-runtime` reads the QEMU commit and checksum from `macos/build-qemu-gpu-runtime.sh` and applies `runtime/patches/qemu-tryomarchy-ios.patch`. The resulting archive does not boot a VM on the Mac. `make ios-firmware` copies `edk2-aarch64-code.fd` into `Resources/firmware/`; that file is not committed.

The app links without the archive. `tryomarchy_qemu_start` is a weak stub until `make ios-runtime` has produced the archive and the app is built again. Boot then says the runtime is missing, which is the stub working.

The iPhone Simulator cannot link that archive. `make ios-simulator-qemu` copies UTM's prebuilt `libqemu-aarch64-softmmu.dylib`, from the `Sysroot-ios_simulator-arm64` artifact, into `ios/.build/utm/Frameworks`. A simulator build of the app loads that library. It is not the pinned Try Omarchy QEMU, and a device build does not use it.
