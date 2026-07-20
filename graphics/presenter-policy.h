#pragma once

#include <stdint.h>

#define DET_PRESENTER_MAX_BUFFERS 6u
#define DET_PRESENTER_MAX_DIMENSION 8192u
#define DET_PRESENTER_MAX_REGISTERED_PIXELS (64ull * 1024ull * 1024ull)
#define DET_PRESENTER_MAX_INFLIGHT_FRAMES 4u

static inline int det_presenter_dimensions_valid(uint32_t width,
                                                  uint32_t height)
{
    return width > 0 && height > 0 &&
           width <= DET_PRESENTER_MAX_DIMENSION &&
           height <= DET_PRESENTER_MAX_DIMENSION;
}

static inline int det_presenter_present_flags_valid(uint32_t flags)
{
    return (flags & ~DET_PRESENTER_HAS_ACQUIRE_FENCE) == 0;
}

static inline int det_presenter_completion_flags_valid(uint32_t flags)
{
    return (flags & ~(DET_PRESENTER_HAS_PRESENT_FENCE |
                      DET_PRESENTER_HAS_RELEASE_FENCE)) == 0;
}
