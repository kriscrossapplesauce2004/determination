#pragma once

#include <stdint.h>

#define DET_FRAMEBUFFER_MAGIC 0x4446524du /* DFRM */
#define DET_FRAMEBUFFER_VERSION 1u
#define DET_FRAMEBUFFER_HEADER_SIZE 4096u
#define DET_FRAMEBUFFER_COUNT 2u

enum det_framebuffer_format {
    /* Little-endian bytes are B, G, R, unused. This is KWin's QPainter
     * virtual-output format and maps to DRM_FORMAT_XRGB8888. */
    DET_FRAMEBUFFER_XRGB8888 = 1,
};

/* The writer fills the inactive buffer, publishes active_index, then release
 * stores sequence. Readers acquire-load sequence before and after copying.
 * Header space is fixed at one page so pixel buffers stay naturally aligned. */
struct det_framebuffer_header {
    uint32_t magic;
    uint32_t version;
    uint32_t header_size;
    uint32_t format;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t buffer_count;
    uint64_t buffer_size;
    uint64_t sequence;
    uint32_t active_index;
    uint32_t reserved0;
    uint64_t monotonic_ns;
    uint64_t reserved[8];
};

