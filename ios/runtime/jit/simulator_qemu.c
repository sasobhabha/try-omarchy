#include "jit26.h"

#include <TargetConditionals.h>

#if TARGET_OS_SIMULATOR

#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The device archive is Mach-O platform iphoneos, so the simulator app cannot
 * link it. This loads UTM's prebuilt simulator library instead. That library
 * is not the pinned Try Omarchy QEMU.
 */
extern char **environ;

static int simulator_bundle_path(char *out, size_t out_len, const char *name)
{
    char executable[PATH_MAX];
    uint32_t size = sizeof executable;

    if (_NSGetExecutablePath(executable, &size) != 0) {
        return -1;
    }
    char *slash = strrchr(executable, '/');
    if (slash == NULL) {
        return -1;
    }
    *slash = '\0';
    int written = snprintf(out, out_len, "%s/%s", executable, name);
    if (written < 0 || (size_t)written >= out_len) {
        return -1;
    }
    return 0;
}

int tryomarchy_qemu_runtime_present(void)
{
    char path[PATH_MAX];

    if (simulator_bundle_path(path, sizeof path, "Frameworks/libqemu-aarch64-softmmu.dylib") != 0) {
        return 0;
    }
    return access(path, R_OK) == 0;
}

int tryomarchy_qemu_start(int argc, char **argv)
{
    char path[PATH_MAX];
    void *handle;
    int (*qemu_init)(int, const char *[], const char *[]);
    void (*qemu_main_loop)(void);
    void (*qemu_cleanup)(void);

    if (simulator_bundle_path(path, sizeof path, "Frameworks/libqemu-aarch64-softmmu.dylib") != 0) {
        return 127;
    }
    handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        fprintf(stderr, "tryomarchy: %s\n", dlerror());
        return 127;
    }
    qemu_init = dlsym(handle, "qemu_init");
    qemu_main_loop = dlsym(handle, "qemu_main_loop");
    qemu_cleanup = dlsym(handle, "qemu_cleanup");
    if (qemu_init == NULL || qemu_main_loop == NULL || qemu_cleanup == NULL) {
        fprintf(stderr, "tryomarchy: %s\n", dlerror());
        return 127;
    }
    /* UTM's library reads its keymaps from the data directory it was built
     * with, which is a path on their build machine. Point -L at the copy in
     * this app.
     */
    char data[PATH_MAX];
    const char *data_dir = NULL;
    if (simulator_bundle_path(data, sizeof data, "qemu-share") == 0 && access(data, R_OK) == 0) {
        data_dir = data;
    }
    int count = argc + (data_dir ? 2 : 0);
    const char **arguments = calloc((size_t)count + 1, sizeof *arguments);
    if (arguments == NULL) {
        return 127;
    }
    arguments[0] = argv[0];
    int next = 1;
    if (data_dir) {
        arguments[next++] = "-L";
        arguments[next++] = data_dir;
    }
    for (int index = 1; index < argc; index++) {
        arguments[next++] = argv[index];
    }
    qemu_init(next, arguments, (const char **)environ);
    free(arguments);
    qemu_main_loop();
    qemu_cleanup();
    return 0;
}

#endif
