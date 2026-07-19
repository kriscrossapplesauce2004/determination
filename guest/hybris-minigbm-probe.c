#define _GNU_SOURCE

/*
 * Determination compatibility graphics gate.
 *
 * Proves that one buffer allocated by Android gralloc through libhybris can:
 *   1. become a vendor-EGL render target; and
 *   2. be imported by minigbm through its dma-buf payload.
 *
 * This deliberately does not use Mesa, Vulkan, Zink, or Turnip. A pass means
 * the device has the minimum seam needed by an Android-backed GBM winsys for
 * desktop compositors. It does not yet prove multi-plane/modifier metadata or
 * presentation; those remain later gates. Explicit producer-fence transport
 * and full AHardwareBuffer Unix-socket transport are covered here.
 */

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <gbm.h>
#include <hybris/common/binding.h>

#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef EGL_NATIVE_BUFFER_HYBRIS
#define EGL_NATIVE_BUFFER_HYBRIS 0x3140
#endif

#ifndef EGL_SYNC_NATIVE_FENCE_ANDROID
#define EGL_SYNC_NATIVE_FENCE_ANDROID 0x3144
#endif
#ifndef EGL_SYNC_NATIVE_FENCE_FD_ANDROID
#define EGL_SYNC_NATIVE_FENCE_FD_ANDROID 0x3145
#endif
#ifndef EGL_NO_NATIVE_FENCE_FD_ANDROID
#define EGL_NO_NATIVE_FENCE_FD_ANDROID -1
#endif

typedef EGLint(EGLAPIENTRYP det_dup_native_fence_fd_fn)(EGLDisplay display,
                                                        EGLSyncKHR sync);

/* Stable NDK/VNDK C ABI. Kept local so this glibc diagnostic doesn't include
 * bionic headers. Android owns the opaque object behind det_ahardware_buffer. */
struct det_native_handle {
    int version;
    int num_fds;
    int num_ints;
    int data[];
};

struct det_ahardware_buffer;

struct det_ahardware_buffer_desc {
    uint32_t width;
    uint32_t height;
    uint32_t layers;
    uint32_t format;
    uint64_t usage;
    uint32_t stride;
    uint32_t rfu0;
    uint64_t rfu1;
};

typedef int (*det_ahb_create_from_handle_fn)(
    const struct det_ahardware_buffer_desc *desc,
    const struct det_native_handle *handle, int32_t method,
    struct det_ahardware_buffer **out_buffer);
typedef int (*det_ahb_send_fn)(const struct det_ahardware_buffer *buffer,
                               int socket_fd);
typedef int (*det_ahb_recv_fn)(int socket_fd,
                               struct det_ahardware_buffer **out_buffer);
typedef void (*det_ahb_describe_fn)(const struct det_ahardware_buffer *buffer,
                                    struct det_ahardware_buffer_desc *desc);
typedef void (*det_ahb_release_fn)(struct det_ahardware_buffer *buffer);

/* Stable Android gralloc0 values also used by libhybris' public extension. */
#define HYBRIS_USAGE_SW_READ_RARELY  0x00000002
#define HYBRIS_USAGE_HW_TEXTURE      0x00000100
#define HYBRIS_USAGE_HW_RENDER       0x00000200
#define HYBRIS_USAGE_HW_COMPOSER     0x00000800
#define HYBRIS_PIXEL_FORMAT_RGBA_8888 1

typedef EGLBoolean(EGLAPIENTRYP det_create_native_buffer_fn)(
    EGLint width, EGLint height, EGLint usage, EGLint format,
    EGLint *stride, EGLClientBuffer *buffer);
typedef EGLBoolean(EGLAPIENTRYP det_lock_native_buffer_fn)(
    EGLClientBuffer buffer, EGLint usage, EGLint left, EGLint top,
    EGLint width, EGLint height, void **address);
typedef EGLBoolean(EGLAPIENTRYP det_unlock_native_buffer_fn)(
    EGLClientBuffer buffer);
typedef EGLBoolean(EGLAPIENTRYP det_release_native_buffer_fn)(
    EGLClientBuffer buffer);
typedef void(EGLAPIENTRYP det_get_native_buffer_info_fn)(
    EGLClientBuffer buffer, int *num_ints, int *num_fds);
typedef void(EGLAPIENTRYP det_serialize_native_buffer_fn)(
    EGLClientBuffer buffer, int *ints, int *fds);
typedef EGLBoolean(EGLAPIENTRYP det_create_remote_buffer_fn)(
    EGLint width, EGLint height, EGLint usage, EGLint format, EGLint stride,
    int num_ints, int *ints, int num_fds, int *fds,
    EGLClientBuffer *buffer);

struct det_egl {
    EGLDisplay display;
    EGLContext context;
    EGLSurface surface;
    PFNEGLCREATEIMAGEKHRPROC create_image;
    PFNEGLDESTROYIMAGEKHRPROC destroy_image;
    PFNEGLCREATESYNCKHRPROC create_sync;
    PFNEGLDESTROYSYNCKHRPROC destroy_sync;
    PFNEGLCLIENTWAITSYNCKHRPROC client_wait_sync;
    det_dup_native_fence_fd_fn dup_native_fence_fd;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_texture;
    PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC image_renderbuffer;
    det_create_native_buffer_fn create_buffer;
    det_lock_native_buffer_fn lock_buffer;
    det_unlock_native_buffer_fn unlock_buffer;
    det_release_native_buffer_fn release_buffer;
    det_get_native_buffer_info_fn get_buffer_info;
    det_serialize_native_buffer_fn serialize_buffer;
    det_create_remote_buffer_fn create_remote_buffer;
};

struct det_render_target {
    EGLImageKHR image;
    GLuint framebuffer;
    GLuint object;
    int renderbuffer;
};

static double monotonic_ms(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static int compare_double(const void *left, const void *right)
{
    const double a = *(const double *)left;
    const double b = *(const double *)right;

    return (a > b) - (a < b);
}

static void report_samples(const char *name, double *samples, int count,
                           const char *unit)
{
    double total = 0.0;

    for (int i = 0; i < count; i++)
        total += samples[i];
    qsort(samples, (size_t)count, sizeof(*samples), compare_double);

    const double mean = total / count;
    const int p50 = (count - 1) * 50 / 100;
    const int p95 = (count - 1) * 95 / 100;
    const int p99 = (count - 1) * 99 / 100;
    const double scale = strcmp(unit, "ms") == 0 ? 1000.0 : 1.0;
    const uint64_t mean_us = (uint64_t)(mean * scale + 0.5);
    const uint64_t p50_us = (uint64_t)(samples[p50] * scale + 0.5);
    const uint64_t p95_us = (uint64_t)(samples[p95] * scale + 0.5);
    const uint64_t p99_us = (uint64_t)(samples[p99] * scale + 0.5);

    printf("BENCH %-20s mean=%" PRIu64 "us p50=%" PRIu64
           "us p95=%" PRIu64 "us p99=%" PRIu64 "us",
           name, mean_us, p50_us, p95_us, p99_us);
    if (strcmp(unit, "ms") == 0 && mean_us > 0) {
        const uint64_t rate_tenths = 10000000 / mean_us;
        printf(" rate=%" PRIu64 ".%" PRIu64 "/s",
               rate_tenths / 10, rate_tenths % 10);
    }
    printf(" samples=%d\n", count);
}

static void fail_egl(const char *what)
{
    fprintf(stderr, "HYBRIS-MINIGBM: FAIL %s (EGL error 0x%04x)\n",
            what, eglGetError());
}

static void *required_proc(const char *name)
{
    void *proc = (void *)eglGetProcAddress(name);
    if (!proc)
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL missing %s\n", name);
    return proc;
}

static int init_egl(struct det_egl *egl)
{
    static const EGLint config_attrs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    static const EGLint pbuffer_attrs[] = {
        EGL_WIDTH, 1,
        EGL_HEIGHT, 1,
        EGL_NONE,
    };
    static const EGLint context_attrs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE,
    };
    EGLConfig config = NULL;
    EGLint count = 0;

    memset(egl, 0, sizeof(*egl));
    egl->display = EGL_NO_DISPLAY;
    egl->context = EGL_NO_CONTEXT;
    egl->surface = EGL_NO_SURFACE;

    egl->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (egl->display == EGL_NO_DISPLAY || !eglInitialize(egl->display, NULL, NULL)) {
        fail_egl("vendor EGL initialization");
        return -1;
    }
    if (!eglBindAPI(EGL_OPENGL_ES_API) ||
        !eglChooseConfig(egl->display, config_attrs, &config, 1, &count) ||
        count != 1) {
        fail_egl("GLES2 config selection");
        return -1;
    }
    egl->surface = eglCreatePbufferSurface(egl->display, config, pbuffer_attrs);
    egl->context = eglCreateContext(egl->display, config, EGL_NO_CONTEXT,
                                    context_attrs);
    if (egl->surface == EGL_NO_SURFACE || egl->context == EGL_NO_CONTEXT ||
        !eglMakeCurrent(egl->display, egl->surface, egl->surface, egl->context)) {
        fail_egl("vendor GLES2 context");
        return -1;
    }

    egl->create_image = (PFNEGLCREATEIMAGEKHRPROC)required_proc("eglCreateImageKHR");
    egl->destroy_image = (PFNEGLDESTROYIMAGEKHRPROC)required_proc("eglDestroyImageKHR");
    egl->create_sync = (PFNEGLCREATESYNCKHRPROC)required_proc("eglCreateSyncKHR");
    egl->destroy_sync = (PFNEGLDESTROYSYNCKHRPROC)required_proc("eglDestroySyncKHR");
    egl->client_wait_sync = (PFNEGLCLIENTWAITSYNCKHRPROC)
        required_proc("eglClientWaitSyncKHR");
    egl->dup_native_fence_fd = (det_dup_native_fence_fd_fn)
        required_proc("eglDupNativeFenceFDANDROID");
    egl->image_texture = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)
        eglGetProcAddress("glEGLImageTargetTexture2DOES");
    egl->image_renderbuffer = (PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC)
        eglGetProcAddress("glEGLImageTargetRenderbufferStorageOES");
    egl->create_buffer = (det_create_native_buffer_fn)
        required_proc("eglHybrisCreateNativeBuffer");
    egl->lock_buffer = (det_lock_native_buffer_fn)
        required_proc("eglHybrisLockNativeBuffer");
    egl->unlock_buffer = (det_unlock_native_buffer_fn)
        required_proc("eglHybrisUnlockNativeBuffer");
    egl->release_buffer = (det_release_native_buffer_fn)
        required_proc("eglHybrisReleaseNativeBuffer");
    egl->get_buffer_info = (det_get_native_buffer_info_fn)
        required_proc("eglHybrisGetNativeBufferInfo");
    egl->serialize_buffer = (det_serialize_native_buffer_fn)
        required_proc("eglHybrisSerializeNativeBuffer");
    egl->create_remote_buffer = (det_create_remote_buffer_fn)
        required_proc("eglHybrisCreateRemoteBuffer");

    if (!egl->create_image || !egl->destroy_image || !egl->create_sync ||
        !egl->destroy_sync || !egl->client_wait_sync ||
        !egl->dup_native_fence_fd ||
        (!egl->image_texture && !egl->image_renderbuffer) ||
        !egl->create_buffer || !egl->lock_buffer ||
        !egl->unlock_buffer || !egl->release_buffer || !egl->get_buffer_info ||
        !egl->serialize_buffer || !egl->create_remote_buffer)
        return -1;

    printf("vendor: %s / %s\n", eglQueryString(egl->display, EGL_VENDOR),
           (const char *)glGetString(GL_RENDERER));
    return 0;
}

static int export_wait_import_fence(struct det_egl *egl)
{
    static const EGLint create_attrs[] = { EGL_NONE };
    EGLSyncKHR producer = EGL_NO_SYNC_KHR;
    EGLSyncKHR consumer = EGL_NO_SYNC_KHR;
    int fence_fd = -1;
    int import_fd = -1;
    struct pollfd poll_fd;
    EGLint import_attrs[3];
    EGLint wait_result;
    int result = -1;

    producer = egl->create_sync(egl->display, EGL_SYNC_NATIVE_FENCE_ANDROID,
                                create_attrs);
    if (producer == EGL_NO_SYNC_KHR) {
        fail_egl("native producer fence creation");
        goto out;
    }
    glFlush();
    fence_fd = egl->dup_native_fence_fd(egl->display, producer);
    if (fence_fd == EGL_NO_NATIVE_FENCE_FD_ANDROID) {
        fail_egl("native producer fence export");
        goto out;
    }

    poll_fd.fd = fence_fd;
    poll_fd.events = POLLIN;
    poll_fd.revents = 0;
    if (poll(&poll_fd, 1, 1500) != 1 || !(poll_fd.revents & POLLIN)) {
        fprintf(stderr,
                "HYBRIS-MINIGBM: FAIL exported native fence did not signal "
                "(revents=0x%x errno=%d)\n",
                poll_fd.revents, errno);
        goto out;
    }

    import_fd = fcntl(fence_fd, F_DUPFD_CLOEXEC, 0);
    if (import_fd < 0)
        goto out;
    import_attrs[0] = EGL_SYNC_NATIVE_FENCE_FD_ANDROID;
    import_attrs[1] = import_fd;
    import_attrs[2] = EGL_NONE;
    consumer = egl->create_sync(egl->display, EGL_SYNC_NATIVE_FENCE_ANDROID,
                                import_attrs);
    if (consumer == EGL_NO_SYNC_KHR) {
        fail_egl("native consumer fence import");
        goto out;
    }
    /* eglCreateSyncKHR owns import_fd after a successful native-fence import. */
    import_fd = -1;
    wait_result = egl->client_wait_sync(egl->display, consumer, 0, 0);
    if (wait_result != EGL_CONDITION_SATISFIED_KHR) {
        fprintf(stderr,
                "HYBRIS-MINIGBM: FAIL imported fence wait result=0x%x\n",
                wait_result);
        goto out;
    }

    printf("native-fence: PASS vendor EGL export, sync-file signal, and EGL import\n");
    result = 0;

out:
    if (consumer != EGL_NO_SYNC_KHR)
        egl->destroy_sync(egl->display, consumer);
    if (producer != EGL_NO_SYNC_KHR)
        egl->destroy_sync(egl->display, producer);
    if (import_fd >= 0)
        close(import_fd);
    if (fence_fd >= 0)
        close(fence_fd);
    return result;
}

static int roundtrip_ahardware_buffer(EGLint width, EGLint height,
                                      EGLint format, EGLint stride,
                                      uint64_t usage, int num_ints,
                                      const int *ints, int num_fds,
                                      const int *fds)
{
    enum { DET_AHB_CREATE_FROM_HANDLE_METHOD_CLONE = 3 };
    void *library = NULL;
    det_ahb_create_from_handle_fn create_from_handle;
    det_ahb_send_fn send_handle;
    det_ahb_recv_fn recv_handle;
    det_ahb_describe_fn describe;
    det_ahb_release_fn release;
    struct det_native_handle *handle = NULL;
    struct det_ahardware_buffer *producer = NULL;
    struct det_ahardware_buffer *consumer = NULL;
    struct det_ahardware_buffer_desc desc = {
        .width = (uint32_t)width,
        .height = (uint32_t)height,
        .layers = 1,
        .format = (uint32_t)format,
        .usage = usage,
        .stride = (uint32_t)stride,
    };
    struct det_ahardware_buffer_desc received = {0};
    int sockets[2] = {-1, -1};
    int result = -1;

    library = android_dlopen("libnativewindow.so", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL open Android libnativewindow: %s\n",
                android_dlerror());
        goto out;
    }
#define DET_AHB_SYMBOL(variable, name)                                      \
    do {                                                                    \
        variable = (__typeof__(variable))android_dlsym(library, name);      \
        if (!(variable)) {                                                  \
            fprintf(stderr, "HYBRIS-MINIGBM: FAIL missing %s\n", name);   \
            goto out;                                                       \
        }                                                                   \
    } while (0)
    DET_AHB_SYMBOL(create_from_handle, "AHardwareBuffer_createFromHandle");
    DET_AHB_SYMBOL(send_handle, "AHardwareBuffer_sendHandleToUnixSocket");
    DET_AHB_SYMBOL(recv_handle, "AHardwareBuffer_recvHandleFromUnixSocket");
    DET_AHB_SYMBOL(describe, "AHardwareBuffer_describe");
    DET_AHB_SYMBOL(release, "AHardwareBuffer_release");
#undef DET_AHB_SYMBOL

    handle = calloc(1, sizeof(*handle) +
                           (size_t)(num_fds + num_ints) * sizeof(int));
    if (!handle)
        goto out;
    handle->version = sizeof(*handle);
    handle->num_fds = num_fds;
    handle->num_ints = num_ints;
    for (int i = 0; i < num_fds; i++)
        handle->data[i] = fds[i];
    for (int i = 0; i < num_ints; i++)
        handle->data[num_fds + i] = ints[i];

    if (create_from_handle(&desc, handle,
                           DET_AHB_CREATE_FROM_HANDLE_METHOD_CLONE,
                           &producer) != 0 || !producer) {
        fprintf(stderr,
                "HYBRIS-MINIGBM: FAIL native_handle -> AHardwareBuffer\n");
        goto out;
    }
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets) != 0)
        goto out;
    if (send_handle(producer, sockets[0]) != 0 ||
        recv_handle(sockets[1], &consumer) != 0 || !consumer) {
        fprintf(stderr,
                "HYBRIS-MINIGBM: FAIL AHardwareBuffer Unix-socket transport\n");
        goto out;
    }
    describe(consumer, &received);
    if (received.width != desc.width || received.height != desc.height ||
        received.layers != 1 || received.format != desc.format ||
        received.stride != desc.stride) {
        fprintf(stderr,
                "HYBRIS-MINIGBM: FAIL transported AHardwareBuffer metadata "
                "%ux%u layers=%u format=%u stride=%u\n",
                received.width, received.height, received.layers,
                received.format, received.stride);
        goto out;
    }

    printf("ahardwarebuffer: PASS full native handle over Unix socket "
           "(%ux%u format=%u stride=%u)\n",
           received.width, received.height, received.format, received.stride);
    result = 0;

out:
    if (consumer && release)
        release(consumer);
    if (producer && release)
        release(producer);
    if (sockets[0] >= 0)
        close(sockets[0]);
    if (sockets[1] >= 0)
        close(sockets[1]);
    free(handle);
    if (library)
        android_dlclose(library);
    return result;
}

static void finish_egl(struct det_egl *egl)
{
    if (egl->display == EGL_NO_DISPLAY)
        return;
    eglMakeCurrent(egl->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (egl->context != EGL_NO_CONTEXT)
        eglDestroyContext(egl->display, egl->context);
    if (egl->surface != EGL_NO_SURFACE)
        eglDestroySurface(egl->display, egl->surface);
    eglTerminate(egl->display);
}

static int create_remote_buffer(struct det_egl *egl, EGLint width,
                                EGLint height, EGLint usage, EGLint format,
                                EGLint stride, int num_ints, int *ints,
                                int num_fds, const int *fds,
                                EGLClientBuffer *buffer)
{
    int *duplicates = calloc((size_t)num_fds, sizeof(*duplicates));

    if (!duplicates)
        return -1;
    for (int i = 0; i < num_fds; i++) {
        duplicates[i] = fcntl(fds[i], F_DUPFD_CLOEXEC, 0);
        if (duplicates[i] < 0) {
            for (int j = 0; j < i; j++)
                close(duplicates[j]);
            free(duplicates);
            return -1;
        }
    }

    /* libhybris closes the descriptors in its temporary native_handle after
     * mapper import, so duplicates must not be closed here after the call. */
    EGLBoolean ok = egl->create_remote_buffer(
        width, height, usage, format, stride, num_ints, ints,
        num_fds, duplicates, buffer);
    free(duplicates);
    return ok && *buffer ? 0 : -1;
}

static int create_render_target(struct det_egl *egl, EGLClientBuffer buffer,
                                struct det_render_target *target)
{
    GLenum status = 0;

    memset(target, 0, sizeof(*target));
    target->image = egl->create_image(egl->display, EGL_NO_CONTEXT,
                                      EGL_NATIVE_BUFFER_HYBRIS, buffer, NULL);
    if (target->image == EGL_NO_IMAGE_KHR)
        return -1;

    glGenFramebuffers(1, &target->framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, target->framebuffer);
    if (egl->image_texture) {
        glGenTextures(1, &target->object);
        glBindTexture(GL_TEXTURE_2D, target->object);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        egl->image_texture(GL_TEXTURE_2D, target->image);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, target->object, 0);
        status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    }
    if (status != GL_FRAMEBUFFER_COMPLETE && egl->image_renderbuffer) {
        if (target->object)
            glDeleteTextures(1, &target->object);
        target->object = 0;
        while (glGetError() != GL_NO_ERROR)
            ;
        glGenRenderbuffers(1, &target->object);
        glBindRenderbuffer(GL_RENDERBUFFER, target->object);
        egl->image_renderbuffer(GL_RENDERBUFFER, target->image);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                  GL_RENDERBUFFER, target->object);
        status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        target->renderbuffer = 1;
    }
    if (status == GL_FRAMEBUFFER_COMPLETE)
        return 0;

    fprintf(stderr, "HYBRIS-MINIGBM: FAIL benchmark FBO status=0x%x\n", status);
    return -1;
}

static void destroy_render_target(struct det_egl *egl,
                                  struct det_render_target *target)
{
    if (target->renderbuffer && target->object)
        glDeleteRenderbuffers(1, &target->object);
    else if (target->object)
        glDeleteTextures(1, &target->object);
    if (target->framebuffer)
        glDeleteFramebuffers(1, &target->framebuffer);
    if (target->image && target->image != EGL_NO_IMAGE_KHR)
        egl->destroy_image(egl->display, target->image);
    memset(target, 0, sizeof(*target));
}

static int render_vendor_egl(struct det_egl *egl, EGLClientBuffer buffer)
{
    EGLImageKHR image;
    GLuint object = 0;
    GLuint framebuffer = 0;
    GLenum status;
    int used_renderbuffer = 0;

    image = egl->create_image(egl->display, EGL_NO_CONTEXT,
                              EGL_NATIVE_BUFFER_HYBRIS, buffer, NULL);
    if (image == EGL_NO_IMAGE_KHR) {
        fail_egl("gralloc buffer → vendor EGLImage");
        return -1;
    }

    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);

    status = 0;
    if (egl->image_texture) {
        glGenTextures(1, &object);
        glBindTexture(GL_TEXTURE_2D, object);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        egl->image_texture(GL_TEXTURE_2D, image);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, object, 0);
        status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    }

    if (status != GL_FRAMEBUFFER_COMPLETE && egl->image_renderbuffer) {
        if (object)
            glDeleteTextures(1, &object);
        object = 0;
        while (glGetError() != GL_NO_ERROR)
            ;
        glGenRenderbuffers(1, &object);
        glBindRenderbuffer(GL_RENDERBUFFER, object);
        egl->image_renderbuffer(GL_RENDERBUFFER, image);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                  GL_RENDERBUFFER, object);
        status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        used_renderbuffer = 1;
    }
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL EGLImage is not renderable (FBO 0x%x)\n",
                status);
        egl->destroy_image(egl->display, image);
        glDeleteFramebuffers(1, &framebuffer);
        return -1;
    }

    glViewport(0, 0, 256, 256);
    while (glGetError() != GL_NO_ERROR)
        ;
    glClearColor(0.25f, 0.50f, 0.75f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    if (export_wait_import_fence(egl) != 0) {
        egl->destroy_image(egl->display, image);
        glDeleteFramebuffers(1, &framebuffer);
        return -1;
    }
    if (glGetError() != GL_NO_ERROR) {
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL vendor GLES render\n");
        egl->destroy_image(egl->display, image);
        glDeleteFramebuffers(1, &framebuffer);
        return -1;
    }

    printf("vendor-egl: PASS (%s-backed EGLImage render target)\n",
           used_renderbuffer ? "renderbuffer" : "texture");
    if (used_renderbuffer)
        glDeleteRenderbuffers(1, &object);
    else
        glDeleteTextures(1, &object);
    glDeleteFramebuffers(1, &framebuffer);
    egl->destroy_image(egl->display, image);
    return 0;
}

static GLuint compile_shader(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    GLint ok = GL_FALSE;

    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        GLsizei length = 0;

        glGetShaderInfoLog(shader, sizeof(log), &length, log);
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL shader compile: %.*s\n",
                (int)length, log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static GLuint create_compositor_program(void)
{
    static const char vertex_source[] =
        "attribute vec2 position;\n"
        "attribute vec2 texcoord;\n"
        "varying vec2 uv;\n"
        "void main() { uv = texcoord; gl_Position = vec4(position, 0.0, 1.0); }\n";
    static const char fragment_source[] =
        "precision mediump float;\n"
        "varying vec2 uv;\n"
        "uniform sampler2D source;\n"
        "uniform vec4 tint;\n"
        "void main() {\n"
        "  vec4 pixel = texture2D(source, uv);\n"
        "  gl_FragColor = vec4(pixel.rgb * tint.rgb * tint.a, tint.a);\n"
        "}\n";
    GLuint vertex = compile_shader(GL_VERTEX_SHADER, vertex_source);
    GLuint fragment = compile_shader(GL_FRAGMENT_SHADER, fragment_source);
    GLuint program = 0;
    GLint ok = GL_FALSE;

    if (!vertex || !fragment)
        goto out;
    program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glBindAttribLocation(program, 0, "position");
    glBindAttribLocation(program, 1, "texcoord");
    glLinkProgram(program);
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024];
        GLsizei length = 0;

        glGetProgramInfoLog(program, sizeof(log), &length, log);
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL program link: %.*s\n",
                (int)length, log);
        glDeleteProgram(program);
        program = 0;
    }

out:
    if (vertex)
        glDeleteShader(vertex);
    if (fragment)
        glDeleteShader(fragment);
    return program;
}

static GLuint create_source_texture(void)
{
    const int edge = 256;
    unsigned char *pixels = malloc((size_t)edge * edge * 4);
    GLuint texture = 0;

    if (!pixels)
        return 0;
    for (int y = 0; y < edge; y++) {
        for (int x = 0; x < edge; x++) {
            size_t offset = ((size_t)y * edge + x) * 4;
            pixels[offset + 0] = (unsigned char)x;
            pixels[offset + 1] = (unsigned char)y;
            pixels[offset + 2] = (unsigned char)(x ^ y);
            pixels[offset + 3] = 255;
        }
    }
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, edge, edge, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    free(pixels);
    if (glGetError() != GL_NO_ERROR) {
        glDeleteTextures(1, &texture);
        return 0;
    }
    return texture;
}

static int benchmark_render(struct det_egl *egl, EGLClientBuffer buffer,
                            int width, int height, int frames)
{
    static const GLfloat vertices[] = {
        -1.0f, -1.0f, 0.0f, 0.0f,
         1.0f, -1.0f, 1.0f, 0.0f,
        -1.0f,  1.0f, 0.0f, 1.0f,
         1.0f,  1.0f, 1.0f, 1.0f,
    };
    static const GLfloat tints[][4] = {
        {1.00f, 0.45f, 0.30f, 0.45f},
        {0.35f, 1.00f, 0.55f, 0.40f},
        {0.40f, 0.55f, 1.00f, 0.35f},
        {1.00f, 0.85f, 0.35f, 0.30f},
    };
    struct det_render_target target = {0};
    double *samples = calloc((size_t)frames, sizeof(*samples));
    GLuint program = 0;
    GLuint texture = 0;
    GLint tint_location;
    int result = -1;

    if (!samples || create_render_target(egl, buffer, &target) != 0)
        goto out;
    glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer);
    glViewport(0, 0, width, height);

    for (int i = -30; i < frames; i++) {
        const double start = monotonic_ms();
        float phase = (float)(i & 15) / 15.0f;
        glClearColor(phase, 0.2f, 1.0f - phase, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glFinish();
        if (i >= 0)
            samples[i] = monotonic_ms() - start;
    }
    report_samples("vendor-clear", samples, frames, "ms");

    program = create_compositor_program();
    texture = create_source_texture();
    if (!program || !texture)
        goto out;
    glUseProgram(program);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture);
    glUniform1i(glGetUniformLocation(program, "source"), 0);
    tint_location = glGetUniformLocation(program, "tint");
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), vertices);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat),
                          vertices + 2);
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

    for (int i = -30; i < frames; i++) {
        const double start = monotonic_ms();
        glClearColor(0.03f, 0.03f, 0.04f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        for (int layer = 0; layer < 4; layer++) {
            glUniform4fv(tint_location, 1, tints[(layer + (i & 3)) & 3]);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        }
        glFinish();
        if (i >= 0)
            samples[i] = monotonic_ms() - start;
    }
    report_samples("vendor-4layer", samples, frames, "ms");
    if (glGetError() != GL_NO_ERROR) {
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL compositor render benchmark\n");
        goto out;
    }
    result = 0;

out:
    glDisable(GL_BLEND);
    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    if (texture)
        glDeleteTextures(1, &texture);
    if (program)
        glDeleteProgram(program);
    destroy_render_target(egl, &target);
    free(samples);
    return result;
}

static int verify_vendor_pixels(struct det_egl *egl, EGLClientBuffer buffer)
{
    unsigned char *pixels = NULL;
    int result = -1;

    if (!egl->lock_buffer(buffer, HYBRIS_USAGE_SW_READ_RARELY,
                          0, 0, 256, 256, (void **)&pixels) || !pixels) {
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL gralloc readback lock\n");
        return -1;
    }
    /* glClearColor(0.25, 0.50, 0.75, 1.0), allowing normal 8-bit rounding. */
    if (pixels[0] >= 62 && pixels[0] <= 65 &&
        pixels[1] >= 126 && pixels[1] <= 129 &&
        pixels[2] >= 190 && pixels[2] <= 193 &&
        pixels[3] >= 254) {
        printf("gralloc-readback: PASS (RGBA=%u,%u,%u,%u)\n",
               pixels[0], pixels[1], pixels[2], pixels[3]);
        result = 0;
    } else {
        fprintf(stderr,
                "HYBRIS-MINIGBM: FAIL rendered pixel mismatch "
                "(RGBA=%u,%u,%u,%u)\n",
                pixels[0], pixels[1], pixels[2], pixels[3]);
    }
    if (!egl->unlock_buffer(buffer)) {
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL gralloc readback unlock\n");
        result = -1;
    }
    return result;
}

static off_t fd_size(int fd)
{
    off_t current = lseek(fd, 0, SEEK_CUR);
    off_t size = lseek(fd, 0, SEEK_END);
    if (current >= 0)
        (void)lseek(fd, current, SEEK_SET);
    return size;
}

static int choose_payload_fd(const int *fds, int count)
{
    int best = -1;
    off_t best_size = -1;

    for (int i = 0; i < count; i++) {
        off_t size = fd_size(fds[i]);
        printf("native-handle: fd[%d]=%d size=%jd\n", i, fds[i],
               (intmax_t)size);
        if (best == -1 || size > best_size) {
            best = i;
            best_size = size;
        }
    }
    return best;
}

static int benchmark_handle_import(struct det_egl *egl, EGLint width,
                                   EGLint height, EGLint usage, EGLint format,
                                   EGLint stride, int num_ints, int *ints,
                                   int num_fds, const int *fds)
{
    const int warmup = 10;
    const int iterations = 100;
    double samples[iterations];

    for (int i = -warmup; i < iterations; i++) {
        EGLClientBuffer remote = NULL;
        const double start = monotonic_ms();

        if (create_remote_buffer(egl, width, height, usage, format, stride,
                                 num_ints, ints, num_fds, fds, &remote) != 0) {
            fprintf(stderr,
                    "HYBRIS-MINIGBM: FAIL benchmark native-handle import\n");
            return -1;
        }
        egl->release_buffer(remote);
        if (i >= 0)
            samples[i] = (monotonic_ms() - start) * 1000.0;
    }
    report_samples("full-handle-roundtrip", samples, iterations, "us");
    return 0;
}

static int benchmark_minigbm_import(const char *node, int fd, uint32_t width,
                                    uint32_t height, uint32_t stride)
{
    const int warmup = 20;
    const int iterations = 300;
    struct gbm_import_fd_data import_data = {
        .fd = fd,
        .width = width,
        .height = height,
        .format = DRM_FORMAT_ABGR8888,
        .stride = stride,
    };
    double samples[iterations];
    struct gbm_device *device = NULL;
    int node_fd = open(node, O_RDWR | O_CLOEXEC);
    int result = -1;

    if (node_fd < 0)
        return -1;
    device = gbm_create_device(node_fd);
    if (!device)
        goto out;

    for (int i = -warmup; i < iterations; i++) {
        const double start = monotonic_ms();
        struct gbm_bo *bo = gbm_bo_import(device, GBM_BO_IMPORT_FD,
                                          &import_data, GBM_BO_USE_RENDERING);
        int exported;

        if (!bo) {
            fprintf(stderr, "HYBRIS-MINIGBM: FAIL benchmark minigbm import\n");
            goto out;
        }
        exported = gbm_bo_get_fd(bo);
        if (exported < 0) {
            gbm_bo_destroy(bo);
            fprintf(stderr, "HYBRIS-MINIGBM: FAIL benchmark minigbm export\n");
            goto out;
        }
        close(exported);
        gbm_bo_destroy(bo);
        if (i >= 0)
            samples[i] = (monotonic_ms() - start) * 1000.0;
    }
    report_samples("minigbm-import-export", samples, iterations, "us");
    result = 0;

out:
    if (device)
        gbm_device_destroy(device);
    close(node_fd);
    return result;
}

static int run_benchmark(struct det_egl *egl, const char *node,
                         int width, int height, int frames, EGLint usage)
{
    EGLClientBuffer buffer = NULL;
    EGLint stride = 0;
    int num_ints = 0;
    int num_fds = 0;
    int *ints = NULL;
    int *fds = NULL;
    int payload = -1;
    int result = -1;

    if (width < 64 || height < 64 || width > 8192 || height > 8192 ||
        frames < 30 || frames > 5000) {
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL invalid benchmark geometry/count\n");
        return -1;
    }
    printf("== benchmark: %dx%d, %d measured frames, 30 warmup ==\n",
           width, height, frames);
    printf("benchmark-note: offscreen glFinish timings; no display/vsync/presenter\n");

    if (!egl->create_buffer(width, height, usage, HYBRIS_PIXEL_FORMAT_RGBA_8888,
                            &stride, &buffer) || !buffer) {
        fail_egl("benchmark gralloc allocation");
        goto out;
    }
    egl->get_buffer_info(buffer, &num_ints, &num_fds);
    if (num_fds <= 0 || num_ints < 0 || num_fds > 32 || num_ints > 1024)
        goto out;
    ints = calloc((size_t)num_ints, sizeof(*ints));
    fds = calloc((size_t)num_fds, sizeof(*fds));
    if ((!ints && num_ints) || !fds)
        goto out;
    egl->serialize_buffer(buffer, ints, fds);
    payload = choose_payload_fd(fds, num_fds);
    if (payload < 0)
        goto out;

    if (benchmark_handle_import(egl, width, height, usage,
                                HYBRIS_PIXEL_FORMAT_RGBA_8888, stride,
                                num_ints, ints, num_fds, fds) != 0)
        goto out;
    printf("benchmark-buffer: original Android gralloc allocation; "
           "round-trip setup cost is reported separately from frame time\n");
    if (benchmark_render(egl, buffer, width, height, frames) != 0)
        goto out;
    if (benchmark_minigbm_import(node, fds[payload], (uint32_t)width,
                                 (uint32_t)height, (uint32_t)stride) != 0)
        goto out;
    printf("HYBRIS-MINIGBM-BENCH: PASS\n");
    result = 0;

out:
    if (buffer)
        egl->release_buffer(buffer);
    free(fds);
    free(ints);
    return result;
}

static int import_minigbm(const char *node, int fd, uint32_t stride)
{
    struct gbm_import_fd_data import_data = {
        .fd = fd,
        .width = 256,
        .height = 256,
        /* Android RGBA byte order maps to DRM ABGR on little-endian CPUs. */
        .format = DRM_FORMAT_ABGR8888,
        .stride = stride,
    };
    struct gbm_device *device = NULL;
    struct gbm_bo *bo = NULL;
    int node_fd = -1;
    int exported = -1;
    int result = -1;

    node_fd = open(node, O_RDWR | O_CLOEXEC);
    if (node_fd < 0) {
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL open %s: %s\n",
                node, strerror(errno));
        goto out;
    }
    device = gbm_create_device(node_fd);
    if (!device) {
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL gbm_create_device(%s)\n", node);
        goto out;
    }
    printf("minigbm: node=%s backend=%s\n", node,
           gbm_device_get_backend_name(device));
    bo = gbm_bo_import(device, GBM_BO_IMPORT_FD, &import_data,
                       GBM_BO_USE_RENDERING);
    if (!bo) {
        fprintf(stderr,
                "HYBRIS-MINIGBM: FAIL Android dma-buf → minigbm import "
                "(format=ABGR8888 stride=%u)\n", stride);
        goto out;
    }
    exported = gbm_bo_get_fd(bo);
    if (exported < 0) {
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL re-export imported BO\n");
        goto out;
    }
    printf("minigbm: PASS (stride=%u modifier=0x%" PRIx64 " re-export-fd=%d)\n",
           gbm_bo_get_stride(bo), (uint64_t)gbm_bo_get_modifier(bo), exported);
    result = 0;

out:
    if (exported >= 0)
        close(exported);
    if (bo)
        gbm_bo_destroy(bo);
    if (device)
        gbm_device_destroy(device);
    if (node_fd >= 0)
        close(node_fd);
    return result;
}

int main(int argc, char **argv)
{
    const char *node = argc > 1 ? argv[1] : "/dev/dri/renderD128";
    const int benchmark = argc > 2 && strcmp(argv[2], "--benchmark") == 0;
    const int benchmark_width = benchmark && argc > 3 ? atoi(argv[3]) : 1080;
    const int benchmark_height = benchmark && argc > 4 ? atoi(argv[4]) : 2340;
    const int benchmark_frames = benchmark && argc > 5 ? atoi(argv[5]) : 240;
    struct det_egl egl;
    EGLClientBuffer buffer = NULL;
    EGLClientBuffer remote_buffer = NULL;
    EGLint stride = 0;
    int num_ints = 0;
    int num_fds = 0;
    int *ints = NULL;
    int *fds = NULL;
    int payload_index = -1;
    int result = 1;
    const EGLint usage = HYBRIS_USAGE_SW_READ_RARELY |
                         HYBRIS_USAGE_HW_TEXTURE |
                         HYBRIS_USAGE_HW_RENDER |
                         HYBRIS_USAGE_HW_COMPOSER;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (access(node, R_OK | W_OK) != 0 && argc == 1)
        node = "/dev/dri/card0";
    if (init_egl(&egl) != 0)
        return 1;
    if (!egl.create_buffer(256, 256, usage, HYBRIS_PIXEL_FORMAT_RGBA_8888,
                           &stride, &buffer) || !buffer) {
        fail_egl("Android gralloc allocation");
        goto out;
    }
    printf("gralloc: PASS (256x256 RGBA8888 stride=%d)\n", stride);

    egl.get_buffer_info(buffer, &num_ints, &num_fds);
    if (num_fds <= 0 || num_ints < 0 || num_fds > 32 || num_ints > 1024) {
        fprintf(stderr,
                "HYBRIS-MINIGBM: FAIL implausible native handle fds=%d ints=%d\n",
                num_fds, num_ints);
        goto out;
    }
    ints = calloc((size_t)num_ints, sizeof(*ints));
    fds = calloc((size_t)num_fds, sizeof(*fds));
    if ((!ints && num_ints) || !fds) {
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL allocation\n");
        goto out;
    }
    egl.serialize_buffer(buffer, ints, fds);
    printf("native-handle: fds=%d private-ints=%d\n", num_fds, num_ints);
    payload_index = choose_payload_fd(fds, num_fds);
    if (payload_index < 0)
        goto out;

    if (!benchmark) {
        if (create_remote_buffer(&egl, 256, 256, usage,
                                 HYBRIS_PIXEL_FORMAT_RGBA_8888, stride,
                                 num_ints, ints, num_fds, fds,
                                 &remote_buffer) != 0) {
            fprintf(stderr,
                    "HYBRIS-MINIGBM: FAIL full native-handle gralloc import\n");
            goto out;
        }
        printf("native-handle: PASS full-handle gralloc round trip\n");
    } else {
        printf("native-handle: SKIP reconstruction in timed process "
               "(covered by det hybrid-probe)\n");
    }

    /* The correctness gate renders through the reconstructed handle and reads
     * through the original. Benchmark mode times mapper round trips separately
     * so one-time setup cost does not contaminate per-frame GPU timings. */
    if (render_vendor_egl(&egl, benchmark ? buffer : remote_buffer) != 0)
        goto out;
    if (verify_vendor_pixels(&egl, buffer) != 0)
        goto out;
    if (import_minigbm(node, fds[payload_index], (uint32_t)stride) != 0)
        goto out;
    if (roundtrip_ahardware_buffer(256, 256,
                                   HYBRIS_PIXEL_FORMAT_RGBA_8888, stride,
                                   (uint64_t)usage, num_ints, ints,
                                   num_fds, fds) != 0)
        goto out;

    if (num_fds > 1) {
        printf("metadata: NOTE multi-fd Android handle; direct compositor support "
               "must preserve the complete native handle\n");
    }
    printf("HYBRIS-MINIGBM: PASS vendor blobs and minigbm share one gralloc buffer\n");
    if (benchmark && run_benchmark(&egl, node, benchmark_width,
                                   benchmark_height, benchmark_frames,
                                   usage) != 0)
        goto out;
    result = 0;

out:
    free(fds);
    free(ints);
    if (remote_buffer)
        egl.release_buffer(remote_buffer);
    if (buffer)
        egl.release_buffer(buffer);
    finish_egl(&egl);
    return result;
}
