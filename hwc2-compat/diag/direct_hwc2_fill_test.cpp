/*
 * direct_hwc2_fill_test — CPU-fill variant of direct_hwc2_test.
 *
 * Same window class, same validate/accept/setClientTarget/present path,
 * but the buffer content is written by the CPU (gralloc lock + solid-fill),
 * not by GLES. The SW usage bits also force QTI gralloc to allocate LINEAR
 * (no UBWC). Panel shows R->G->B cycling => the present path is good and
 * the GL test's blackness is on the GPU-write/UBWC side. Panel stays black
 * => the present path itself never gets our content to scanout.
 *
 * Derived from direct_hwc2_test.cpp (Apache-2.0, TheKit / Carsten Munk).
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <inttypes.h>
#include <mutex>
#include <condition_variable>

#include <cutils/log.h>
#include <sync/sync.h>
#include <sys/ioctl.h>
#include <linux/dma-buf.h>

#include "hybris-gralloc.h"
#include <hwcomposer_window.h>

#include "hwc2_compatibility_layer.h"

extern "C" hwc2_error_t hwc2_compat_display_set_brightness(
        hwc2_compat_display_t* display, float brightness);

std::mutex hotplugMutex;
std::condition_variable hotplugCv;
hwc2_compat_device_t* hwcDevice;

// FILL_MODE env: which submission path carries the pixels.
//   client — buffer as the composer client target (GL test's path)
//   device — buffer on the layer, composition DEVICE (what SF actually
//            does on this ROM: baseline dump shows Device/Device)
//   solid  — SOLID_COLOR layer, no buffer at all: the DPU generates the
//            color, taking gralloc/fetch entirely out of the path
enum FillMode { MODE_CLIENT, MODE_DEVICE, MODE_SOLID };
FillMode g_mode = MODE_CLIENT;
// SF's client target dataspace on this device (V0_SRGB), vs the UNKNOWN
// the stock test sends.
#define FILL_DATASPACE ((android_dataspace_t)0x8810000)
int g_colorSlot = 0;

class HWComposer : public HWComposerNativeWindow
{
    private:
        hwc2_compat_layer_t *layer;
        hwc2_compat_display_t *hwcDisplay;
        HWComposerNativeWindowBuffer *lastBuffer;
    protected:
        void present(HWComposerNativeWindowBuffer *buffer);

    public:
        HWComposer(unsigned int width, unsigned int height, unsigned int format,
                hwc2_compat_display_t *display, hwc2_compat_layer_t *layer);
        ~HWComposer();
};

HWComposer::HWComposer(unsigned int width, unsigned int height,
                    unsigned int format, hwc2_compat_display_t* display,
                    hwc2_compat_layer_t *layer) :
                    HWComposerNativeWindow(width, height, format)
{
    this->layer = layer;
    this->hwcDisplay = display;
    this->lastBuffer = NULL;
}

HWComposer::~HWComposer()
{
    if (lastBuffer)
        lastBuffer->common.decRef(&lastBuffer->common);
}

void HWComposer::present(HWComposerNativeWindowBuffer *buffer)
{
    uint32_t numTypes = 0;
    uint32_t numRequests = 0;
    static bool demotedLogged = false;

    // Layer state must be in place before validate (SF's order).
    if (g_mode == MODE_DEVICE) {
        hwc2_compat_layer_set_buffer(layer, /* slot */0, buffer,
                                     getFenceBufferFd(buffer));
    } else if (g_mode == MODE_SOLID) {
        static const hwc_color_t solidCols[3] =
            { {255,0,0,255}, {0,255,0,255}, {0,0,255,255} };
        hwc2_compat_layer_set_color(layer, solidCols[g_colorSlot]);
    }

    hwc2_error_t error = hwc2_compat_display_validate(hwcDisplay, &numTypes,
                                                      &numRequests);

    if (error != HWC2_ERROR_NONE && error != HWC2_ERROR_HAS_CHANGES) {
        fprintf(stderr, "validate failed: %d\n", error);
        return;
    }

    bool demoted = (numTypes || numRequests);
    if (demoted && !demotedLogged) {
        demotedLogged = true;
        fprintf(stderr, "validate demoted composition: types=%u requests=%u"
                " (falling back to client target)\n", numTypes, numRequests);
    }

    error = hwc2_compat_display_accept_changes(hwcDisplay);
    if (error != HWC2_ERROR_NONE) {
        fprintf(stderr, "acceptChanges failed: %d\n", error);
        return;
    }

    if (g_mode == MODE_CLIENT || demoted) {
        hwc2_compat_display_set_client_target(hwcDisplay, /* slot */0, buffer,
                                              g_mode == MODE_CLIENT
                                                  ? getFenceBufferFd(buffer) : -1,
                                              FILL_DATASPACE);
    }

    int presentFence = -1;
    error = hwc2_compat_display_present(hwcDisplay, &presentFence);

    // Frame-delivery proof: the present fence signals when this frame is on
    // screen. Wait on a dup so the normal reuse path keeps its fd.
    {
        static int dosFrame = 0;
        ++dosFrame;
        if (dosFrame <= 3 || dosFrame % 120 == 0) {
            int w = -2;
            if (presentFence >= 0) {
                int d = dup(presentFence);
                w = sync_wait(d, 1500);
                close(d);
            }
            fprintf(stderr, "FILL-DIAG present#%d rc=%d presentFence=%d sync_wait=%d(%s)\n",
                    dosFrame, error, presentFence, w,
                    w == 0 ? "SIGNALED-on-screen" : strerror(errno));
        }
    }

    if (error != HWC2_ERROR_NONE) {
        fprintf(stderr, "present failed: %d\n", error);
        return;
    }

    hwc2_compat_out_fences_t* fences;
    error = hwc2_compat_display_get_release_fences(hwcDisplay, &fences);
    if (error != HWC2_ERROR_NONE) {
        fprintf(stderr, "getReleaseFences failed: %d\n", error);
        return;
    }

    int fenceFd = hwc2_compat_out_fences_get_fence(fences, layer);
    setFenceBufferFd(buffer, fenceFd);
    hwc2_compat_out_fences_destroy(fences);

    if (lastBuffer) {
        int lastFd = getFenceBufferFd(lastBuffer);
        if (lastFd != -1)
            close(lastFd);
        setFenceBufferFd(lastBuffer, presentFence);
        lastBuffer->common.decRef(&lastBuffer->common);
    } else if (presentFence != -1) {
        close(presentFence);
    }

    lastBuffer = buffer;
    lastBuffer->common.incRef(&lastBuffer->common);
}

void onVsyncReceived(HWC2EventListener* listener, int32_t sequenceId,
                     hwc2_display_t display, int64_t timestamp)
{
}

void onHotplugReceived(HWC2EventListener* listener, int32_t sequenceId,
                       hwc2_display_t display, bool connected,
                       bool primaryDisplay)
{
    ALOGI("onHotplugReceived(%d, %" PRIu64 ", %s, %s)",
        sequenceId, display,
        connected ? "connected" : "disconnected",
        primaryDisplay ? "primary" : "external");

    {
        std::lock_guard<std::mutex> lock(hotplugMutex);
        hwc2_compat_device_on_hotplug(hwcDevice, display, connected);
    }

    hotplugCv.notify_all();
}

void onRefreshReceived(HWC2EventListener* listener,
                       int32_t sequenceId, hwc2_display_t display)
{
}

HWC2EventListener eventListener = {
    &onVsyncReceived,
    &onHotplugReceived,
    &onRefreshReceived
};

int main()
{
    int composerSequenceId = 0;

    hwcDevice = hwc2_compat_device_new(false);
    assert(hwcDevice);

    hwc2_compat_device_register_callback(hwcDevice, &eventListener,
                                         composerSequenceId);

    std::unique_lock<std::mutex> lock(hotplugMutex);
    hwc2_compat_display_t* hwcDisplay;
    while (!(hwcDisplay = hwc2_compat_device_get_display_by_id(hwcDevice, 0))) {
        hotplugCv.wait_for(lock, std::chrono::seconds(5));
    }
    hotplugMutex.unlock();
    assert(hwcDisplay);

    // A no-op ON (SDM already believes state==On after SF ran) never sends
    // the DCS wake sequence; a command-mode panel left asleep then ACKs DMA
    // (fences signal) while showing black. OFF->ON forces a real panel
    // re-init.
    if (getenv("FILL_POWER_CYCLE")) {
        fprintf(stderr, "power cycle: OFF\n");
        hwc2_compat_display_set_power_mode(hwcDisplay, HWC2_POWER_MODE_OFF);
        usleep(500000);
        fprintf(stderr, "power cycle: ON\n");
    }
    hwc2_compat_display_set_power_mode(hwcDisplay, HWC2_POWER_MODE_ON);
    if (getenv("FILL_VSYNC"))
        hwc2_compat_display_set_vsync_enabled(hwcDisplay, HWC2_VSYNC_ENABLE);
    // SDM keeps its own brightness state (DSPP dimming, fod_native mode) on
    // top of the sysfs backlight; a client that never sets it may present
    // into a fully dimmed pipeline.
    if (getenv("FILL_BRIGHTNESS")) {
        hwc2_error_t be = hwc2_compat_display_set_brightness(hwcDisplay, 1.0f);
        fprintf(stderr, "set_brightness(1.0) rc=%d\n", be);
    }

    std::shared_ptr<HWC2DisplayConfig> config = {
        hwc2_compat_display_get_active_config(hwcDisplay), free };

    printf("width: %i height: %i\n", config->width, config->height);

    const char *modeEnv = getenv("FILL_MODE");
    if (modeEnv && !strcmp(modeEnv, "device")) g_mode = MODE_DEVICE;
    else if (modeEnv && !strcmp(modeEnv, "solid")) g_mode = MODE_SOLID;
    fprintf(stderr, "mode: %s\n",
            g_mode == MODE_DEVICE ? "device" :
            g_mode == MODE_SOLID ? "solid" : "client");

    hwc2_compat_layer_t* layer = hwc2_compat_display_create_layer(hwcDisplay);

    hwc2_compat_layer_set_composition_type(layer,
            g_mode == MODE_DEVICE ? HWC2_COMPOSITION_DEVICE :
            g_mode == MODE_SOLID ? HWC2_COMPOSITION_SOLID_COLOR :
            HWC2_COMPOSITION_CLIENT);
    if (g_mode != MODE_SOLID)
        hwc2_compat_layer_set_dataspace(layer, FILL_DATASPACE);
    hwc2_compat_layer_set_blend_mode(layer, HWC2_BLEND_MODE_NONE);
    hwc2_compat_layer_set_source_crop(layer, 0.0f, 0.0f, config->width,
                                      config->height);
    hwc2_compat_layer_set_display_frame(layer, 0, 0, config->width,
                                        config->height);
    hwc2_compat_layer_set_visible_region(layer, 0, 0, config->width,
                                         config->height);

    HWComposer *win = new HWComposer(config->width, config->height,
                                     HAL_PIXEL_FORMAT_RGBA_8888, hwcDisplay,
                                     layer);
    hybris_gralloc_initialize(0);

    ANativeWindow *anw = static_cast<ANativeWindow *>(win);
    // Before the first dequeue (= first allocation): CPU access + linear.
    // setUsage() ORs HW_COMPOSER|HW_FB back in.
    uint64_t usage = GRALLOC_USAGE_SW_READ_OFTEN | GRALLOC_USAGE_SW_WRITE_OFTEN;
    int rc = anw->perform(anw, NATIVE_WINDOW_SET_USAGE64, usage);
    printf("set_usage64 rc=%d\n", rc);

    // RGBA_8888 memory order is R,G,B,A => little-endian words 0xAABBGGRR.
    static const uint32_t cols[3] = { 0xFF0000FFu, 0xFF00FF00u, 0xFFFF0000u };
    static const char *names[3] = { "RED", "GREEN", "BLUE" };

    for (int i = 0; ; ++i) {
        ANativeWindowBuffer *buf = NULL;
        int fence = -1;
        rc = anw->dequeueBuffer(anw, &buf, &fence);
        if (rc || !buf) {
            fprintf(stderr, "dequeueBuffer rc=%d buf=%p\n", rc, buf);
            return 2;
        }
        if (fence >= 0) {
            sync_wait(fence, 3000);
            close(fence);
        }

        void *vaddr = NULL;
        rc = hybris_gralloc_lock(buf->handle,
                GRALLOC_USAGE_SW_READ_OFTEN | GRALLOC_USAGE_SW_WRITE_OFTEN,
                0, 0, buf->width, buf->height, &vaddr);
        if (rc || !vaddr) {
            fprintf(stderr, "gralloc_lock rc=%d vaddr=%p\n", rc, vaddr);
            return 3;
        }

        // The buffer is CPU-cached; without explicit cache maintenance the
        // DPU can scan stale DRAM (black) while our pixels sit in cache —
        // CPU readback still sees them, so prev-content proves nothing.
        // dma-buf sync ioctls on the ion fd do the clean/invalidate.
        int dmafd = (buf->handle && buf->handle->numFds > 0)
                        ? buf->handle->data[0] : -1;
        struct dma_buf_sync dbs;
        if (dmafd >= 0) {
            dbs.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE;
            int src = ioctl(dmafd, DMA_BUF_IOCTL_SYNC, &dbs);
            if (i == 0)
                fprintf(stderr, "dma-buf sync START rc=%d errno=%d fd=%d\n",
                        src, src ? errno : 0, dmafd);
        }

        int slot = (i / 180) % 3;
        g_colorSlot = slot;
        uint32_t px = cols[slot];
        uint32_t *row = (uint32_t *)vaddr;
        uint32_t before = row[0];
        for (int y = 0; y < buf->height; ++y, row += buf->stride)
            for (int x = 0; x < buf->width; ++x)
                row[x] = px;

        if (i < 3 || i % 180 == 0)
            fprintf(stderr,
                "FILL #%d %s w=%d h=%d stride=%d fmt=0x%x usage=0x%" PRIx64
                " vaddr=%p prev-content=0x%08x\n",
                i, names[slot], buf->width, buf->height, buf->stride,
                buf->format, (uint64_t)buf->usage, vaddr, before);

        if (dmafd >= 0) {
            dbs.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE;
            int src = ioctl(dmafd, DMA_BUF_IOCTL_SYNC, &dbs);
            if (i == 0)
                fprintf(stderr, "dma-buf sync END rc=%d errno=%d\n",
                        src, src ? errno : 0);
        }
        hybris_gralloc_unlock(buf->handle);
        anw->queueBuffer(anw, buf, -1);
        usleep(16666);
    }

    return 0;
}
