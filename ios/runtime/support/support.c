#include "support.h"

#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) __attribute__((weak_import));
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement,
                                                 CFErrorRef *error) __attribute__((weak_import));

#if TRYOMARCHY_HAS_ZSTD
#include <zstd.h>
#endif

int tryomarchy_zstd_available(void)
{
#if TRYOMARCHY_HAS_ZSTD
    return 1;
#else
    return 0;
#endif
}

long long tryomarchy_zstd_content_size(const char *source)
{
#if TRYOMARCHY_HAS_ZSTD
    unsigned char header[18];
    int fd = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    ssize_t count;
    unsigned long long size;

    if (fd < 0) {
        return -1;
    }
    count = read(fd, header, sizeof header);
    close(fd);
    if (count <= 0) {
        return -1;
    }
    size = ZSTD_getFrameContentSize(header, (size_t)count);
    if (size == ZSTD_CONTENTSIZE_UNKNOWN || size == ZSTD_CONTENTSIZE_ERROR ||
        size > (unsigned long long)LLONG_MAX) {
        return -1;
    }
    return (long long)size;
#else
    (void)source;
    return -1;
#endif
}

#if TRYOMARCHY_HAS_ZSTD
/* iOS applies F_NOCACHE only when the buffer, the file offset, and the length
 * are multiples of the page size, 16 KiB on this device. A write that misses
 * that alignment stays in the file cache, and iOS jetsams this process once
 * the unpacked disk, about 20 GiB, no longer fits. The simulator does not.
 * Callers write full pages from a page-aligned buffer. F_NOCACHE_EXT covers
 * the final partial page. */
static int set_uncached(int fd)
{
    if (fcntl(fd, F_NOCACHE, 1) != 0) {
        return -1;
    }
    (void)fcntl(fd, F_NOCACHE_EXT, 1);
    (void)fcntl(fd, F_GLOBAL_NOCACHE, 1);
    (void)fcntl(fd, F_RDAHEAD, 0);
    return 0;
}

static void *page_alloc(size_t page, size_t bytes)
{
    void *buffer = NULL;

    if (page == 0 || bytes == 0 || posix_memalign(&buffer, page, bytes) != 0) {
        return NULL;
    }
    return buffer;
}

static ssize_t read_amount(int fd, void *buffer, size_t bytes)
{
    size_t got = 0;

    while (got < bytes) {
        ssize_t count = read(fd, (char *)buffer + got, bytes - got);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0) {
            return -1;
        }
        if (count == 0) {
            break;
        }
        got += (size_t)count;
    }
    return (ssize_t)got;
}

static int write_full(int fd, const void *buffer, size_t bytes)
{
    const char *cursor = buffer;
    size_t left = bytes;

    while (left > 0) {
        ssize_t count = write(fd, cursor, left);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            return -1;
        }
        cursor += count;
        left -= (size_t)count;
    }
    return 0;
}

static int emit_disk(int fd, char *pending, size_t *pending_len, size_t chunk,
                     unsigned long long *since_sync, const void *bytes, size_t count, int finish)
{
    const char *src = bytes;

    while (count > 0) {
        size_t space = chunk - *pending_len;
        size_t take = count < space ? count : space;

        memcpy(pending + *pending_len, src, take);
        *pending_len += take;
        src += take;
        count -= take;
        if (*pending_len == chunk) {
            if (write_full(fd, pending, chunk) != 0) {
                return -1;
            }
            *pending_len = 0;
            *since_sync += chunk;
            if (*since_sync >= (64ull << 20)) {
                if (fsync(fd) != 0) {
                    return -1;
                }
                *since_sync = 0;
            }
        }
    }
    if (finish && *pending_len > 0) {
        if (write_full(fd, pending, *pending_len) != 0) {
            return -1;
        }
        *pending_len = 0;
    }
    return 0;
}
#endif

int tryomarchy_zstd_decompress_file(const char *source, const char *destination)
{
#if !TRYOMARCHY_HAS_ZSTD
    (void)source;
    (void)destination;
    return -1;
#else
    int input = -1;
    int output = -1;
    ZSTD_DCtx *context = NULL;
    void *input_buffer = NULL;
    void *output_buffer = NULL;
    char *pending = NULL;
    size_t page = (size_t)getpagesize();
    size_t chunk = (size_t)1 << 20;
    size_t output_size = ZSTD_DStreamOutSize();
    size_t pending_len = 0;
    unsigned long long since_sync = 0;
    int failed = 0;

    if (page == 0 || (page & (page - 1)) != 0) {
        return -1;
    }
    if (chunk < page) {
        chunk = page;
    }
    chunk -= chunk % page;

    input = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (input < 0) {
        return -1;
    }
    output = open(destination, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (output < 0) {
        close(input);
        return -1;
    }
    if (fchmod(output, 0600) != 0 || set_uncached(input) != 0 || set_uncached(output) != 0) {
        failed = 1;
        goto done;
    }
    context = ZSTD_createDCtx();
    input_buffer = page_alloc(page, chunk);
    output_buffer = malloc(output_size);
    pending = page_alloc(page, chunk);
    if (!context || !input_buffer || !output_buffer || !pending) {
        failed = 1;
        goto done;
    }

    size_t last_result = 1;
    for (;;) {
        ssize_t read_count = read_amount(input, input_buffer, chunk);
        ZSTD_inBuffer in;

        if (read_count < 0) {
            failed = 1;
            break;
        }
        if (read_count == 0) {
            while (!failed && last_result != 0) {
                ZSTD_inBuffer empty = {input_buffer, 0, 0};
                ZSTD_outBuffer out = {output_buffer, output_size, 0};
                size_t result = ZSTD_decompressStream(context, &out, &empty);

                if (ZSTD_isError(result) || out.pos == 0) {
                    failed = 1;
                    break;
                }
                last_result = result;
                if (emit_disk(output, pending, &pending_len, chunk, &since_sync, output_buffer, out.pos, 0) != 0) {
                    failed = 1;
                }
            }
            break;
        }
        in.src = input_buffer;
        in.size = (size_t)read_count;
        in.pos = 0;
        while (in.pos < in.size) {
            size_t consumed = in.pos;
            ZSTD_outBuffer out = {output_buffer, output_size, 0};
            size_t result = ZSTD_decompressStream(context, &out, &in);

            if (ZSTD_isError(result)) {
                failed = 1;
                break;
            }
            last_result = result;
            if (emit_disk(output, pending, &pending_len, chunk, &since_sync, output_buffer, out.pos, 0) != 0) {
                failed = 1;
                break;
            }
            if (out.pos == 0 && in.pos == consumed) {
                failed = 1;
                break;
            }
        }
        if (failed) {
            break;
        }
    }
    if (!failed && last_result != 0) {
        failed = 1;
    }
    if (!failed && emit_disk(output, pending, &pending_len, chunk, &since_sync, NULL, 0, 1) != 0) {
        failed = 1;
    }

done:
    if (!failed && output >= 0 && fsync(output) != 0) {
        failed = 1;
    }
    free(input_buffer);
    free(output_buffer);
    free(pending);
    ZSTD_freeDCtx(context);
    if (input >= 0) {
        close(input);
    }
    if (output >= 0) {
        close(output);
    }
    if (failed) {
        unlink(destination);
        return -1;
    }
    return 0;
#endif
}

int tryomarchy_task_allows_jit(void)
{
    SecTaskRef task;
    CFTypeRef value;
    int allowed = 0;

    if (!SecTaskCreateFromSelf || !SecTaskCopyValueForEntitlement) {
        return 0;
    }
    task = SecTaskCreateFromSelf(NULL);
    if (!task) {
        return 0;
    }
    value = SecTaskCopyValueForEntitlement(task, CFSTR("get-task-allow"), NULL);
    if (value) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            allowed = CFBooleanGetValue(value) ? 1 : 0;
        }
        CFRelease(value);
    }
    CFRelease(task);
    return allowed;
}
