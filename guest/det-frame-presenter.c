#define _GNU_SOURCE

/*
 * Determination KWin-frame -> Android external-display presenter.
 *
 * KWin's virtual QPainter backend publishes XRGB8888 frames into a small
 * double-buffered mmap. This process copies them into Android gralloc buffers
 * allocated through libhybris, converts BGRA byte order to RGBA, and hands the
 * buffers to the companion's AHardwareBuffer presenter. No Mesa stack is used.
 */

#include <EGL/egl.h>
#include <hybris/common/binding.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "framebuffer-protocol.h"
#include "presenter-client.h"

#define HYBRIS_USAGE_SW_WRITE_OFTEN 0x00000030
#define HYBRIS_USAGE_HW_COMPOSER    0x00000800
#define HYBRIS_PIXEL_FORMAT_RGBA_8888 1

typedef EGLBoolean(EGLAPIENTRYP det_create_native_buffer_fn)(
    EGLint, EGLint, EGLint, EGLint, EGLint *, EGLClientBuffer *);
typedef EGLBoolean(EGLAPIENTRYP det_lock_native_buffer_fn)(
    EGLClientBuffer, EGLint, EGLint, EGLint, EGLint, EGLint, void **);
typedef EGLBoolean(EGLAPIENTRYP det_unlock_native_buffer_fn)(EGLClientBuffer);
typedef EGLBoolean(EGLAPIENTRYP det_release_native_buffer_fn)(EGLClientBuffer);
typedef void(EGLAPIENTRYP det_get_native_buffer_info_fn)(EGLClientBuffer,
                                                         int *, int *);
typedef void(EGLAPIENTRYP det_serialize_native_buffer_fn)(EGLClientBuffer,
                                                          int *, int *);

struct det_gralloc {
    EGLDisplay display;
    det_create_native_buffer_fn create;
    det_lock_native_buffer_fn lock;
    det_unlock_native_buffer_fn unlock;
    det_release_native_buffer_fn release;
    det_get_native_buffer_info_fn info;
    det_serialize_native_buffer_fn serialize;
};

struct det_buffer {
    EGLClientBuffer handle;
    int stride;
    int release_fence;
};

static volatile sig_atomic_t running = 1;

static void stop_running(int signal_number)
{
    (void)signal_number;
    running = 0;
}

static void *required_proc(const char *name)
{
    void *proc = (void *)eglGetProcAddress(name);
    if (!proc)
        fprintf(stderr, "det-frame-presenter: missing %s\n", name);
    return proc;
}

static int gralloc_init(struct det_gralloc *gralloc)
{
    memset(gralloc, 0, sizeof(*gralloc));
    gralloc->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (gralloc->display == EGL_NO_DISPLAY ||
        !eglInitialize(gralloc->display, NULL, NULL)) {
        fprintf(stderr, "det-frame-presenter: EGL init failed 0x%x\n",
                eglGetError());
        return -1;
    }
    gralloc->create = (det_create_native_buffer_fn)
        required_proc("eglHybrisCreateNativeBuffer");
    gralloc->lock = (det_lock_native_buffer_fn)
        required_proc("eglHybrisLockNativeBuffer");
    gralloc->unlock = (det_unlock_native_buffer_fn)
        required_proc("eglHybrisUnlockNativeBuffer");
    gralloc->release = (det_release_native_buffer_fn)
        required_proc("eglHybrisReleaseNativeBuffer");
    gralloc->info = (det_get_native_buffer_info_fn)
        required_proc("eglHybrisGetNativeBufferInfo");
    gralloc->serialize = (det_serialize_native_buffer_fn)
        required_proc("eglHybrisSerializeNativeBuffer");
    return gralloc->create && gralloc->lock && gralloc->unlock &&
           gralloc->release && gralloc->info && gralloc->serialize ? 0 : -1;
}

static int wait_fence(int *fd)
{
    if (*fd < 0)
        return 0;
    struct pollfd item = {.fd = *fd, .events = POLLIN};
    int status;
    do {
        status = poll(&item, 1, 5000);
    } while (status < 0 && errno == EINTR && running);
    close(*fd);
    *fd = -1;
    return status > 0 ? 0 : -1;
}

static int register_buffer(struct det_gralloc *gralloc,
                           struct det_presenter_client *client,
                           struct det_buffer *buffer, uint64_t id,
                           uint32_t width, uint32_t height)
{
    const EGLint usage = HYBRIS_USAGE_SW_WRITE_OFTEN |
                         HYBRIS_USAGE_HW_COMPOSER;
    int num_ints = 0;
    int num_fds = 0;
    int *ints = NULL;
    int *fds = NULL;
    int status = -1;

    if (!gralloc->create((EGLint)width, (EGLint)height, usage,
                         HYBRIS_PIXEL_FORMAT_RGBA_8888, &buffer->stride,
                         &buffer->handle) || !buffer->handle)
        return -1;
    gralloc->info(buffer->handle, &num_ints, &num_fds);
    if (num_ints < 0 || num_ints > 128 || num_fds <= 0 || num_fds > 16)
        return -1;
    ints = calloc((size_t)num_ints, sizeof(*ints));
    fds = calloc((size_t)num_fds, sizeof(*fds));
    if ((!ints && num_ints) || !fds)
        goto out;
    gralloc->serialize(buffer->handle, ints, fds);
    status = det_presenter_register_buffer(client, id, width, height,
                                            HYBRIS_PIXEL_FORMAT_RGBA_8888,
                                            (uint32_t)buffer->stride,
                                            (uint64_t)usage, num_ints, ints,
                                            num_fds, fds);
out:
    free(fds);
    free(ints);
    return status;
}

static void copy_xrgb_to_rgba(uint8_t *destination, uint32_t dest_stride,
                              const uint8_t *source, uint32_t source_stride,
                              uint32_t width, uint32_t height)
{
    for (uint32_t y = 0; y < height; y++) {
        uint8_t *out = destination + (size_t)y * dest_stride * 4;
        const uint8_t *in = source + (size_t)y * source_stride;
        for (uint32_t x = 0; x < width; x++) {
            out[x * 4 + 0] = in[x * 4 + 2];
            out[x * 4 + 1] = in[x * 4 + 1];
            out[x * 4 + 2] = in[x * 4 + 0];
            out[x * 4 + 3] = 255;
        }
    }
}

static int validate_header(const struct det_framebuffer_header *header,
                           size_t mapped_size)
{
    uint64_t frame_bytes;
    if (header->magic != DET_FRAMEBUFFER_MAGIC ||
        header->version != DET_FRAMEBUFFER_VERSION ||
        header->header_size != DET_FRAMEBUFFER_HEADER_SIZE ||
        header->format != DET_FRAMEBUFFER_XRGB8888 ||
        header->buffer_count != DET_FRAMEBUFFER_COUNT ||
        header->width == 0 || header->width > 8192 ||
        header->height == 0 || header->height > 8192 ||
        header->stride < header->width * 4)
        return -1;
    frame_bytes = (uint64_t)header->stride * header->height;
    if (header->buffer_size < frame_bytes ||
        header->buffer_size > SIZE_MAX / DET_FRAMEBUFFER_COUNT ||
        DET_FRAMEBUFFER_HEADER_SIZE +
            header->buffer_size * DET_FRAMEBUFFER_COUNT > mapped_size)
        return -1;
    return 0;
}

int main(int argc, char **argv)
{
    const char *frame_path;
    const char *socket_path;
    struct det_framebuffer_header *header = MAP_FAILED;
    struct det_presenter_client client = {.fd = -1};
    struct det_gralloc gralloc = {0};
    struct det_buffer buffers[2] = {{.release_fence = -1},
                                    {.release_fence = -1}};
    struct stat stat_buffer;
    int frame_fd = -1;
    uint64_t seen = 0;
    uint64_t serial = 0;
    int result = 1;

    if (argc != 3) {
        fprintf(stderr, "usage: %s FRAMEBUFFER PRESENTER_SOCKET\n", argv[0]);
        return 2;
    }
    frame_path = argv[1];
    socket_path = argv[2];
    signal(SIGINT, stop_running);
    signal(SIGTERM, stop_running);

    while (running && (frame_fd = open(frame_path, O_RDONLY | O_CLOEXEC)) < 0) {
        if (errno != ENOENT) {
            perror("det-frame-presenter: open framebuffer");
            goto out;
        }
        usleep(100000);
    }
    if (!running || fstat(frame_fd, &stat_buffer) != 0 || stat_buffer.st_size <= 0)
        goto out;
    header = mmap(NULL, (size_t)stat_buffer.st_size, PROT_READ, MAP_SHARED,
                  frame_fd, 0);
    if (header == MAP_FAILED ||
        validate_header(header, (size_t)stat_buffer.st_size) != 0) {
        fprintf(stderr, "det-frame-presenter: invalid framebuffer header\n");
        goto out;
    }
    if (gralloc_init(&gralloc) != 0 ||
        det_presenter_connect(&client, socket_path) != 0) {
        perror("det-frame-presenter: presenter setup");
        goto out;
    }
    for (unsigned int i = 0; i < 2; i++) {
        if (register_buffer(&gralloc, &client, &buffers[i], i + 1,
                            header->width, header->height) != 0) {
            perror("det-frame-presenter: register buffer");
            goto out;
        }
    }
    fprintf(stderr, "det-frame-presenter: streaming %ux%u via libhybris gralloc\n",
            header->width, header->height);

    while (running) {
        uint64_t sequence = __atomic_load_n(&header->sequence, __ATOMIC_ACQUIRE);
        if (sequence == 0 || sequence == seen) {
            usleep(4000);
            continue;
        }
        uint32_t source_index = __atomic_load_n(&header->active_index,
                                                __ATOMIC_RELAXED);
        unsigned int target_index = (unsigned int)(serial & 1u);
        void *pixels = NULL;
        if (source_index >= DET_FRAMEBUFFER_COUNT ||
            wait_fence(&buffers[target_index].release_fence) != 0)
            goto out;
        if (!gralloc.lock(buffers[target_index].handle,
                          HYBRIS_USAGE_SW_WRITE_OFTEN, 0, 0,
                          (EGLint)header->width, (EGLint)header->height,
                          &pixels) || !pixels) {
            fprintf(stderr, "det-frame-presenter: gralloc lock failed\n");
            goto out;
        }
        const uint8_t *source = (const uint8_t *)header +
            DET_FRAMEBUFFER_HEADER_SIZE + source_index * header->buffer_size;
        copy_xrgb_to_rgba(pixels, (uint32_t)buffers[target_index].stride,
                          source, header->stride, header->width, header->height);
        if (!gralloc.unlock(buffers[target_index].handle))
            goto out;
        if (__atomic_load_n(&header->sequence, __ATOMIC_ACQUIRE) != sequence)
            continue;

        struct det_presenter_packet completion;
        struct pollfd ready = {.fd = client.fd, .events = POLLIN};
        int present_fence = -1;
        serial++;
        if (det_presenter_present(&client, serial, target_index + 1, 0, -1) != 0 ||
            poll(&ready, 1, 5000) <= 0 ||
            det_presenter_receive_completion(&client, &completion,
                                              &present_fence,
                                              &buffers[target_index].release_fence) != 0 ||
            completion.status != 0 || completion.serial != serial) {
            fprintf(stderr, "det-frame-presenter: present failed\n");
            if (present_fence >= 0)
                close(present_fence);
            goto out;
        }
        if (present_fence >= 0)
            close(present_fence);
        seen = sequence;
    }
    result = 0;

out:
    det_presenter_disconnect(&client);
    for (unsigned int i = 0; i < 2; i++) {
        if (buffers[i].release_fence >= 0)
            close(buffers[i].release_fence);
        if (buffers[i].handle && gralloc.release)
            gralloc.release(buffers[i].handle);
    }
    if (header != MAP_FAILED)
        munmap(header, (size_t)stat_buffer.st_size);
    if (frame_fd >= 0)
        close(frame_fd);
    if (gralloc.display && gralloc.display != EGL_NO_DISPLAY)
        eglTerminate(gralloc.display);
    return result;
}
