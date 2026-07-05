/*
 * Extra hwc2_compat entry points the upstream compatibility layer doesn't
 * expose. Compiled straight into the diag binaries (the wrapper structs are
 * one-pointer PODs; mirror them here instead of patching the cloned tree).
 */

#include <ui/Fence.h>

#include "HWC2.h"
#include "ComposerHal.h"
#include "hwc2_compatibility_layer.h"

struct hwc2_compat_display
{
    android::HWC2::Display *self;
};

extern "C" hwc2_error_t hwc2_compat_display_set_brightness(
        hwc2_compat_display* display, float brightness)
{
    android::Hwc2::Composer::DisplayBrightnessOptions opts{
        .applyImmediately = true};
    auto error = display->self
            ->setDisplayBrightness(brightness, -1.0f, opts).get();
    return static_cast<hwc2_error_t>(error);
}
