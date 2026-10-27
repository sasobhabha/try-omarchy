#pragma once

int tryomarchy_zstd_available(void);
long long tryomarchy_zstd_content_size(const char *source);
int tryomarchy_zstd_decompress_file(const char *source, const char *destination);
int tryomarchy_task_allows_jit(void);
