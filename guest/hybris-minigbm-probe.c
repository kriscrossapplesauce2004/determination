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
 * presentation; those remain later gates.
 */

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <gbm.h>

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef EGL_NATIVE_BUFFER_HYBRIS
#define EGL_NATIVE_BUFFER_HYBRIS 0x3140
#endif

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

    if (!egl->create_image || !egl->destroy_image ||
        (!egl->image_texture && !egl->image_renderbuffer) ||
        !egl->create_buffer || !egl->lock_buffer ||
        !egl->unlock_buffer || !egl->release_buffer || !egl->get_buffer_info ||
        !egl->serialize_buffer || !egl->create_remote_buffer)
        return -1;

    printf("vendor: %s / %s\n", eglQueryString(egl->display, EGL_VENDOR),
           (const char *)glGetString(GL_RENDERER));
    return 0;
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
    glFinish(); /* baseline correctness; explicit native fences are a later gate */
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
    struct det_egl egl;
    EGLClientBuffer buffer = NULL;
    EGLClientBuffer remote_buffer = NULL;
    EGLint stride = 0;
    int num_ints = 0;
    int num_fds = 0;
    int *ints = NULL;
    int *fds = NULL;
    int *remote_fds = NULL;
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

    /* eglHybrisCreateRemoteBuffer builds a temporary native_handle and closes
     * its fds after mapper import. Give it duplicates so the allocating
     * ANativeWindowBuffer keeps ownership of its original descriptors. */
    remote_fds = calloc((size_t)num_fds, sizeof(*remote_fds));
    if (!remote_fds) {
        fprintf(stderr, "HYBRIS-MINIGBM: FAIL remote fd allocation\n");
        goto out;
    }
    for (int i = 0; i < num_fds; i++) {
        remote_fds[i] = fcntl(fds[i], F_DUPFD_CLOEXEC, 0);
        if (remote_fds[i] < 0) {
            fprintf(stderr, "HYBRIS-MINIGBM: FAIL duplicate native-handle fd: %s\n",
                    strerror(errno));
            for (int j = 0; j < i; j++)
                close(remote_fds[j]);
            goto out;
        }
    }
    if (!egl.create_remote_buffer(256, 256, usage,
                                  HYBRIS_PIXEL_FORMAT_RGBA_8888, stride,
                                  num_ints, ints, num_fds, remote_fds,
                                  &remote_buffer) || !remote_buffer) {
        fprintf(stderr,
                "HYBRIS-MINIGBM: FAIL full native-handle gralloc import\n");
        goto out;
    }
    printf("native-handle: PASS full-handle gralloc round trip\n");

    /* Render through the reconstructed handle, then read through the original
     * allocation. This proves both wrappers reference the same Android BO. */
    if (render_vendor_egl(&egl, remote_buffer) != 0)
        goto out;
    if (verify_vendor_pixels(&egl, buffer) != 0)
        goto out;
    if (import_minigbm(node, fds[payload_index], (uint32_t)stride) != 0)
        goto out;

    if (num_fds > 1) {
        printf("metadata: NOTE multi-fd Android handle; direct compositor support "
               "must preserve the complete native handle\n");
    }
    printf("HYBRIS-MINIGBM: PASS vendor blobs and minigbm share one gralloc buffer\n");
    result = 0;

out:
    free(remote_fds);
    free(fds);
    free(ints);
    if (remote_buffer)
        egl.release_buffer(remote_buffer);
    if (buffer)
        egl.release_buffer(buffer);
    finish_egl(&egl);
    return result;
}
