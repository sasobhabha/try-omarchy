#pragma once

#include <stddef.h>

int tryomarchy_debugger_attached(void);
int tryomarchy_xcode_jit(void);
int tryomarchy_jit_protocol_required(void);
void *JIT26PrepareRegion(void *address, size_t length);
void JIT26Detach(void);

int tryomarchy_qemu_start(int argc, char **argv);
int tryomarchy_qemu_runtime_present(void);
