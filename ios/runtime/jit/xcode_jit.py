"""Answer the iOS 26 translator breakpoint for Xcode's debugserver.

StikDebug's universal.js does this when it is the debugger. Xcode does not
load that script. Allocating with the debugger, then writing one byte of
each page through the debugger, is what makes the page executable. Skipping
JIT26Detach leaves this debug session attached.
"""

import lldb

PAGE = 16384


def set_register(frame, name, value):
    register = frame.FindRegister(name)
    error = lldb.SBError()
    if not register.IsValid() or not register.SetValueFromCString(
        "%#x" % value, error
    ) or not error.Success():
        print("JIT_REG_FAIL %s %s" % (name, error), flush=True)
        return False
    return True


def mnemonic(target, pc):
    address = lldb.SBAddress(pc, target)
    instructions = target.ReadInstructions(address, 1)
    if instructions.GetSize() < 1:
        return ""
    return instructions.GetInstructionAtIndex(0).GetMnemonic(target)


def return_pc(target, pc):
    word = mnemonic(target, pc)
    # The helpers are mov, brk, ret. A breakpoint stops on the mov.
    # The brk itself stops on the brk. Either way the next ret is the return.
    if word == "brk":
        return pc + 4
    if word == "mov":
        return pc + 8
    if word == "ret":
        return pc
    print("JIT_SHAPE_FAIL %s at %#x" % (word, pc), flush=True)
    return None


def handle_jit_stop(debugger, command, result, internal_dict):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    thread = process.GetSelectedThread()
    for candidate in process:
        if candidate.GetStopReason() == lldb.eStopReasonBreakpoint:
            thread = candidate
            break
    frame = thread.GetSelectedFrame()
    name = frame.GetFunctionName() or ""
    pc = frame.FindRegister("pc").GetValueAsUnsigned()
    print("JIT_STOP %s pc=%#x insn=%s" % (name, pc, mnemonic(target, pc)), flush=True)
    destination = return_pc(target, pc)
    if destination is None:
        return
    if "JIT26Detach" in name:
        if set_register(frame, "pc", destination):
            print("JIT_SKIPPED_DETACH", flush=True)
        return
    if "JIT26PrepareRegion" not in name:
        print("JIT_UNEXPECTED", flush=True)
        return
    size = frame.FindRegister("x1").GetValueAsUnsigned()
    if size == 0 or size > 256 * 1024 * 1024 or size % PAGE != 0:
        print("JIT_ALLOC_FAIL bad size %#x" % size, flush=True)
        return
    error = lldb.SBError()
    permissions = lldb.ePermissionsReadable | lldb.ePermissionsExecutable
    address = process.AllocateMemory(size, permissions, error)
    if (
        not error.Success()
        or address == 0
        or address == lldb.LLDB_INVALID_ADDRESS
    ):
        print("JIT_ALLOC_FAIL %s" % error, flush=True)
        return
    print("JIT_ALLOCATED %#x" % address, flush=True)
    offset = 0
    pages = size // PAGE
    while offset < size:
        written = process.WriteMemory(address + offset, b"\x69", error)
        if not error.Success() or written != 1:
            print(
                "JIT_TOUCH_FAIL %#x %s" % (address + offset, error),
                flush=True,
            )
            return
        offset += PAGE
        done = offset // PAGE
        if done % 1024 == 0 or done == pages:
            print("JIT_TOUCH %d/%d" % (done, pages), flush=True)
    if not set_register(frame, "x0", address):
        return
    if not set_register(frame, "pc", destination):
        return
    print("JIT_READY %#x" % address, flush=True)


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        "command script add -f xcode_jit.handle_jit_stop handle_jit_stop"
    )
