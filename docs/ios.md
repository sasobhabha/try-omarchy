# iOS

The iOS app is a second shell for the same factory disk the Mac app boots. The guest stays stock Omarchy. Nothing in this shell changes the `try-omarchy` package or any file Omarchy owns.

A sideloaded app cannot use Hypervisor.framework, and iOS 26 does not let the app spawn another process that receives JIT. QEMU's TCG translator therefore runs inside the app process. StikDebug attaches a debugger to that process so the translator can be made executable. The app does not embed StikDebug.

## What boots

The CPU is TCG (`-accel tcg,thread=multi,split-wx=on`), not HVF. The machine is `virt` with the same edk2 firmware the Mac runtime stages, a writable 64 MiB variable store, and the factory disk on virtio-blk. The disk stays the size of the factory image.

The display is virtio-gpu's 2D framebuffer, served by QEMU's VNC on `127.0.0.1:5900`. The app ships QEMU's keymaps and passes `-L` at that directory, because the data directory compiled into QEMU is a path on the build Mac. Without the keymap, VNC fails to open and QEMU quits before the firmware draws. When the VM starts, the framebuffer takes the shape of the display, and the client follows a later change to that size. The app draws the whole picture fitted to the window, and refits it when the window changes size. The app asks for the whole framebuffer several times a second, because virtio-gpu often reports no changed region after the firmware logo. Hyprland and wlroots do not start, because this shell does not pass a VirGL display. UEFI, Limine, and the kernel text console are what the screen shows.

There is no audio, clipboard, camera, battery report, shared folder, or QMP. The guest still receives the host keyboard, locale, and time zone through the same `tryomarchy.host` SMBIOS credential the Mac launcher writes, without the VirGL flag.

## JIT

The app opens `stikdebug://enable-jit` with its bundle identifier and process id. On iOS 26 it also names `universal.js`. Opening the URL is not enough: the app waits until the kernel reports the process as traced, and only then starts QEMU.

Launching from Xcode attaches a debugger before the process starts. The app then shows JIT as Xcode and does not open StikDebug. On iOS 26 and later that attachment is not enough. TXM ignores a process `mprotect` that adds execute, so the translator asks the debugger to allocate one executable region. StikDebug's `universal.js` answers that request. Xcode's debugserver answers it when `ios/runtime/jit/xcode_jit.py` is loaded. A breakpoint with no handler stops the process.

On iOS 26 and later the translator asks for that region with a null address, remaps a writable alias of the same pages, and then detaches the script. A later region cannot be prepared. The translator cache is capped (`tb-size=128`) so it stays one region. On earlier iOS versions, debugger attachment alone is what allows the executable mapping.

The iOS SDK does not provide `pthread_jit_write_protect_np`. The translator writes one mapping and executes another, and boot forces `split-wx=on` so it never falls back to a single `MAP_JIT` buffer.

The app is not an App Store build. It needs the `get-task-allow` entitlement and Developer Mode. JIT comes from Xcode's debugger, or from StikDebug with a pairing file and LocalDevVPN. Signing that entitlement is a person's step in Xcode. The build commands do not sign.

## Download and storage

The app ships the same `download.json` the Mac app carries for a release. It downloads the published image parts over HTTPS, checks each part, then checks the decompressed disk against `identity`. An existing `disk.img` is left in place. Deleting the VM removes the storage folder only after a confirmation.

Storage matches the Mac layout under Application Support: `Try Omarchy/VM/v1/`, the same storage-root marker, `shell/disk.img`, `shell/efi-vars.fd`, and `shell-factory/<identity>.img.zst`.

Unpacking writes the disk in page-sized pieces, which keeps those pages out of the file cache. Boot reads it the same way. iOS counts that cache against the app and quits the process once the unpacked disk, about 20 GiB, no longer fits, even though the guest itself uses 2 GiB of RAM. The simulator does not.

## Building

`make test-ios` runs the shell's contracts on the Mac: the manifest, the download, the boot arguments, the VNC parser, and a source check that the QEMU patch still has the iOS entry points. `make ios-app` compiles the unsigned app against weak QEMU stubs, so the app links before the translator exists. `make ios` cross-compiles the pinned QEMU (the same commit as `macos/build-qemu-gpu-runtime.sh`) into a static archive, stages the firmware, and compiles the app again with that archive loaded. The archive is the object files from the unsigned QEMU link, and it is force-loaded so it replaces the weak stub. The static libraries on that link line, including libstubs, are searched afterwards, so a stub is linked only when the real object is absent. CI runs `make test-ios`. It does not cross-compile QEMU, and it does not boot a device.

The archive's `tryomarchy_qemu_start` runs `qemu_init` and the main loop and returns. It does not call `exit` on the success path. The app calls it on a dedicated thread. Device boot is not something this repository can check in CI.

The iPhone Simulator cannot link the device archive. A simulator build looks for `Frameworks/libqemu-aarch64-softmmu.dylib` and calls that library's `qemu_init`. `make ios-simulator-qemu` fills the directory from UTM's prebuilt `Sysroot-ios_simulator-arm64` artifact, and copies QEMU's keymaps into the app so the display can open. That library is not the pinned Try Omarchy QEMU. The simulator process has no StikDebug attach, so the simulator app starts QEMU without waiting for a debugger. A device build still waits. If `TRYOMARCHY_BOOT` is set and the disk is already installed, the app boots when the window opens. On a device that still waits until a debugger is attached.
