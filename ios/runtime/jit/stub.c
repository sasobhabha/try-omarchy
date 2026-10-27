#include "jit26.h"

__attribute__((weak))
int tryomarchy_qemu_start(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    return 127;
}

__attribute__((weak))
int tryomarchy_qemu_runtime_present(void)
{
    return 0;
}
