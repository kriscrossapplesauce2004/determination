/*
 * Extra hwc2_compat entry points the upstream compatibility layer doesn't
 * expose. Compiled straight into the diag binaries (the wrapper structs are
 * one-pointer PODs; mirror them here instead of patching the cloned tree).
 */

#include <ui/Fence.h>

#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <sys/ioctl.h>
#include <sys/syscall.h>

#include "HWC2.h"
#include "ComposerHal.h"
#include "hwc2_compatibility_layer.h"

struct hwc2_compat_display
{
    android::HWC2::Display *self;
};

// Interpose fmq/hidl's logError: the guest has no logd, so ALOG is a black
// hole — FMQ setup failures (the exact class of bug behind the NO_RESOURCES
// wall, 2026-07-05) would be invisible. This object links before
// device-libs/*.so with --allow-multiple-definition, so our definition wins
// inside the compat layer.
namespace android { namespace hardware { namespace details {
void logError(const std::string& message) {
    fprintf(stderr, "DOS-FMQ-ERR: %s\n", message.c_str());
}
}}}

// Interpose libcutils' ashmem_create_region for the same reason: modern
// libcutils opens /dev/ashmem<boot_id>, a per-boot node name a container
// generally lacks; its failure surfaces as composer-FMQ creation dying and
// every hwc2 validate returning NO_RESOURCES (found 2026-07-05). Speak the
// classic /dev/ashmem ioctl protocol directly, fall back to memfd.
#define DOS_ASHMEMIOC 0x77
#define DOS_ASHMEM_SET_NAME _IOW(DOS_ASHMEMIOC, 1, char[256])
#define DOS_ASHMEM_SET_SIZE _IOW(DOS_ASHMEMIOC, 3, size_t)
#define DOS_ASHMEM_SET_PROT _IOW(DOS_ASHMEMIOC, 5, unsigned long)

extern "C" int ashmem_create_region(const char* name, size_t size)
{
    int fd = open("/dev/ashmem", O_RDWR | O_CLOEXEC);
    if (fd >= 0) {
        if (name) {
            char buf[256];
            strncpy(buf, name, sizeof(buf) - 1);
            buf[255] = '\0';
            ioctl(fd, DOS_ASHMEM_SET_NAME, buf);
        }
        if (ioctl(fd, DOS_ASHMEM_SET_SIZE, size) == 0)
            return fd;
        int e = errno;
        close(fd);
        fprintf(stderr, "DOS-ASHMEM: SET_SIZE failed errno=%d\n", e);
    } else {
        fprintf(stderr, "DOS-ASHMEM: open /dev/ashmem failed errno=%d\n", errno);
    }
    fd = (int)syscall(__NR_memfd_create, name ? name : "ashmem-shim",
                      1 /* MFD_CLOEXEC */);
    if (fd >= 0 && ftruncate(fd, (off_t)size) == 0)
        return fd;
    fprintf(stderr, "DOS-ASHMEM: memfd fallback failed errno=%d\n", errno);
    if (fd >= 0)
        close(fd);
    return -1;
}

extern "C" int ashmem_set_prot_region(int fd, int prot)
{
    ioctl(fd, DOS_ASHMEM_SET_PROT, (unsigned long)prot);
    return 0;  // memfd has no ashmem ioctls; mapping enforces prot anyway
}

extern "C" hwc2_error_t hwc2_compat_display_set_brightness(
        hwc2_compat_display* display, float brightness)
{
    android::Hwc2::Composer::DisplayBrightnessOptions opts{
        .applyImmediately = true};
    auto error = display->self
            ->setDisplayBrightness(brightness, -1.0f, opts).get();
    return static_cast<hwc2_error_t>(error);
}
