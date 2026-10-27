#include "jit26.h"

#include <TargetConditionals.h>
#include <stdlib.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

int tryomarchy_debugger_attached(void)
{
    struct kinfo_proc info;
    size_t size = sizeof info;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};

    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return 0;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

/*
 * Xcode's debugger attaches before this process starts. StikDebug attaches
 * later, after the app asks it to. On iOS 26 and later, TXM ignores a
 * process mprotect that adds execute, so both debuggers are asked for an
 * executable mapping through the breakpoint below.
 */
static int debugger_attached_at_launch;

__attribute__((constructor))
static void tryomarchy_record_launch_debugger(void)
{
    debugger_attached_at_launch = tryomarchy_debugger_attached();
}

int tryomarchy_xcode_jit(void)
{
    return debugger_attached_at_launch && tryomarchy_debugger_attached();
}

int tryomarchy_jit_protocol_required(void)
{
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    char version[32] = {0};
    size_t length = sizeof version;

    /*
     * A compiler availability check emits a weak import of an availability
     * helper. QEMU's configure links every probe with -Wl,-no_weak_imports,
     * and that weak reference makes shm_open look missing. iOS has no librt,
     * so the build stops. kern.osproductversion is the same major-version check.
     */
    if (sysctlbyname("kern.osproductversion", version, &length, NULL, 0) != 0) {
        return 0;
    }
    return atoi(version) >= 26;
#else
    return 0;
#endif
}

__attribute__((noinline, optnone, naked, used))
void JIT26Detach(void)
{
    __asm__ volatile(
        "mov x16, #0\n"
        "brk #0xf00d\n"
        "ret\n");
}

__attribute__((noinline, optnone, naked, used))
void *JIT26PrepareRegion(void *address __attribute__((unused)), size_t length __attribute__((unused)))
{
    __asm__ volatile(
        "mov x16, #1\n"
        "brk #0xf00d\n"
        "ret\n");
}
