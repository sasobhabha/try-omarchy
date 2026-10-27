# iPhone and iPad

Try Omarchy can download and boot the same Omarchy factory disk on an iPhone or iPad. The guest runs in a virtual machine inside the app. This build is sideloaded. It is not an App Store app.

What you see is the text console from UEFI, the boot menu, and the kernel. The Omarchy desktop does not start: this virtual machine has no GPU the desktop can use.

## What you need

- An iPhone or iPad on iOS 17.4 or newer, with about 25 GB free. The download is about 3 GB. The unpacked disk is the factory image, about 20 GB, and unpacking keeps about 1 GB free beyond that.
- A copy of the app signed with a development certificate so it includes `get-task-allow`. Developer Mode has to be on.
- [StikDebug](https://github.com/StephenDev0/StikDebug) with a pairing file from a computer that trusts the device. On iOS 17.4 through 18, Xcode's debugger can be used instead.
- LocalDevVPN, running, when StikDebug is what attaches the debugger. Xcode does not need it.

Signing and installing the app is something you do in Xcode. The project does not sign itself.

## First launch

1. Open **Try Omarchy**.
2. Tap **Download Omarchy**. The download resumes if it is interrupted. The app checks the file before it unpacks it. Unpacking takes several minutes. Leave this screen open until the app says Omarchy is ready to boot.
3. For JIT on iOS 26 and later, start LocalDevVPN, tap **Enable JIT**, approve the prompt in StikDebug, and switch back. StikDebug allocates the translator's executable memory. On earlier iOS versions, leaving the app under Xcode's debugger is enough.
4. Tap **Boot**. When Xcode is attached, **JIT** reads **Xcode** and **Enable JIT** stays off. On iOS 26 and later that debugger still has to allocate the executable region; attachment alone does not.

If the app is running inside LiveContainer, turn on **Use LiveContainer's Bundle ID** in StikDebug before enabling JIT.

The screen stays on while Omarchy is running. Leaving the app suspends it, and the virtual machine with it. Bring the app back to continue.

The picture fits the display. Folding or rotating refits it. The guest uses the new shape the next time it boots.

A hardware keyboard types into the console. The on-screen row sends Esc, Tab, Ctrl, Alt, and the arrow keys. Touch moves the pointer.

## Starting over

**Delete VM** asks first, then removes the downloaded disk. The next boot needs a new download. Memory can be 2, 3, or 4 GB. The CPU count can be from 1 to 8.

## What this build does not do

There is no sound, clipboard, camera, or shared folder. The network is the virtual machine's own address, not the device's. Shut the guest down from its console before you delete the VM.
