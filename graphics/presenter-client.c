#define _GNU_SOURCE

#include "presenter-client.h"
#include "presenter-policy.h"

#include <hybris/common/binding.h>

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

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

typedef int (*det_create_from_handle_fn)(
    const struct det_ahardware_buffer_desc *desc,
    const struct det_native_handle *handle, int32_t method,
    struct det_ahardware_buffer **out_buffer);
typedef int (*det_send_handle_fn)(const struct det_ahardware_buffer *buffer,
                                  int socket_fd);
typedef void (*det_release_buffer_fn)(struct det_ahardware_buffer *buffer);

static int send_packet(int fd, struct det_presenter_packet *packet,
                       int fence_fd)
{
    struct iovec iov = {
        .iov_base = packet,
        .iov_len = sizeof(*packet),
    };
    char control[CMSG_SPACE(sizeof(int))] = {0};
    struct msghdr message = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
    };

    if (fence_fd >= 0) {
        struct cmsghdr *header;

        message.msg_control = control;
        message.msg_controllen = sizeof(control);
        header = CMSG_FIRSTHDR(&message);
        header->cmsg_level = SOL_SOCKET;
        header->cmsg_type = SCM_RIGHTS;
        header->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(header), &fence_fd, sizeof(int));
    }
    return sendmsg(fd, &message, MSG_NOSIGNAL) == (ssize_t)sizeof(*packet)
        ? 0 : -1;
}

int det_presenter_connect(struct det_presenter_client *client,
                          const char *socket_path)
{
    struct sockaddr_un address = {.sun_family = AF_UNIX};

    memset(client, 0, sizeof(*client));
    client->fd = -1;
    if (!socket_path || strlen(socket_path) >= sizeof(address.sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    client->nativewindow = android_dlopen("libnativewindow.so",
                                         RTLD_NOW | RTLD_LOCAL);
    if (!client->nativewindow)
        goto fail;
    client->create_from_handle = android_dlsym(
        client->nativewindow, "AHardwareBuffer_createFromHandle");
    client->send_handle = android_dlsym(
        client->nativewindow, "AHardwareBuffer_sendHandleToUnixSocket");
    client->release_buffer = android_dlsym(
        client->nativewindow, "AHardwareBuffer_release");
    if (!client->create_from_handle || !client->send_handle ||
        !client->release_buffer) {
        errno = ENOSYS;
        goto fail;
    }
    client->fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (client->fd < 0)
        goto fail;
    memcpy(address.sun_path, socket_path, strlen(socket_path) + 1);
    if (connect(client->fd, (struct sockaddr *)&address, sizeof(address)) != 0)
        goto fail;
    return 0;

fail:
    det_presenter_disconnect(client);
    return -1;
}

void det_presenter_disconnect(struct det_presenter_client *client)
{
    if (client->fd >= 0)
        close(client->fd);
    if (client->nativewindow)
        android_dlclose(client->nativewindow);
    memset(client, 0, sizeof(*client));
    client->fd = -1;
}

int det_presenter_register_buffer(struct det_presenter_client *client,
                                  uint64_t buffer_id, uint32_t width,
                                  uint32_t height, uint32_t format,
                                  uint32_t stride, uint64_t usage,
                                  int num_ints, const int *ints,
                                  int num_fds, const int *fds)
{
    enum { DET_CREATE_FROM_HANDLE_METHOD_CLONE = 3 };
    det_create_from_handle_fn create_from_handle =
        (det_create_from_handle_fn)client->create_from_handle;
    det_send_handle_fn send_handle =
        (det_send_handle_fn)client->send_handle;
    det_release_buffer_fn release_buffer =
        (det_release_buffer_fn)client->release_buffer;
    struct det_native_handle *handle = NULL;
    struct det_ahardware_buffer *buffer = NULL;
    struct det_ahardware_buffer_desc desc = {
        .width = width,
        .height = height,
        .layers = 1,
        .format = format,
        .usage = usage,
        .stride = stride,
    };
    struct det_presenter_packet packet =
        det_presenter_packet_init(DET_PRESENTER_REGISTER);
    int status = -1;

    if (client->fd < 0 || buffer_id == 0 ||
        !det_presenter_dimensions_valid(width, height) ||
        num_fds <= 0 || num_fds > 16 ||
        num_ints < 0 || num_ints > 128 || !fds || (num_ints && !ints)) {
        errno = EINVAL;
        return -1;
    }
    handle = calloc(1, sizeof(*handle) +
                           (size_t)(num_fds + num_ints) * sizeof(int));
    if (!handle)
        return -1;
    handle->version = sizeof(*handle);
    handle->num_fds = num_fds;
    handle->num_ints = num_ints;
    memcpy(handle->data, fds, (size_t)num_fds * sizeof(int));
    memcpy(handle->data + num_fds, ints, (size_t)num_ints * sizeof(int));
    if (create_from_handle(&desc, handle,
                           DET_CREATE_FROM_HANDLE_METHOD_CLONE,
                           &buffer) != 0 || !buffer)
        goto out;

    packet.buffer_id = buffer_id;
    packet.width = width;
    packet.height = height;
    packet.format = format;
    packet.stride = stride;
    packet.usage = usage;
    if (send_packet(client->fd, &packet, -1) != 0)
        goto out;
    if (send_handle(buffer, client->fd) != 0)
        goto out;
    status = 0;

out:
    if (buffer)
        release_buffer(buffer);
    free(handle);
    return status;
}

int det_presenter_present(struct det_presenter_client *client,
                          uint64_t serial, uint64_t buffer_id,
                          uint64_t desired_present_time_ns,
                          int acquire_fence_fd)
{
    struct det_presenter_packet packet =
        det_presenter_packet_init(DET_PRESENTER_PRESENT);

    if (client->fd < 0 || serial == 0 || buffer_id == 0) {
        errno = EINVAL;
        return -1;
    }
    packet.serial = serial;
    packet.buffer_id = buffer_id;
    packet.desired_present_time_ns = desired_present_time_ns;
    if (acquire_fence_fd >= 0)
        packet.flags |= DET_PRESENTER_HAS_ACQUIRE_FENCE;
    return send_packet(client->fd, &packet, acquire_fence_fd);
}

int det_presenter_receive_completion(struct det_presenter_client *client,
                                     struct det_presenter_packet *packet,
                                     int *present_fence_fd,
                                     int *release_fence_fd)
{
    struct iovec iov = {
        .iov_base = packet,
        .iov_len = sizeof(*packet),
    };
    int received_fds[2] = {-1, -1};
    char control[CMSG_SPACE(sizeof(received_fds))] = {0};
    struct msghdr message = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = control,
        .msg_controllen = sizeof(control),
    };
    ssize_t size;
    size_t fd_count = 0;
    struct cmsghdr *header;

    *present_fence_fd = -1;
    *release_fence_fd = -1;
    size = recvmsg(client->fd, &message, MSG_CMSG_CLOEXEC);
    header = CMSG_FIRSTHDR(&message);
    if (header && header->cmsg_level == SOL_SOCKET &&
        header->cmsg_type == SCM_RIGHTS) {
        fd_count = (header->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        if (fd_count > 2)
            fd_count = 2;
        memcpy(received_fds, CMSG_DATA(header), fd_count * sizeof(int));
    }
    if (size != (ssize_t)sizeof(*packet) ||
        (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) ||
        packet->magic != DET_PRESENTER_MAGIC ||
        packet->version != DET_PRESENTER_VERSION ||
        packet->size != sizeof(*packet) ||
        packet->op != DET_PRESENTER_COMPLETE ||
        !det_presenter_completion_flags_valid(packet->flags)) {
        goto bad_fds;
    }
    size_t index = 0;
    if (packet->flags & DET_PRESENTER_HAS_PRESENT_FENCE) {
        if (index >= fd_count)
            goto bad_fds;
        *present_fence_fd = received_fds[index++];
    }
    if (packet->flags & DET_PRESENTER_HAS_RELEASE_FENCE) {
        if (index >= fd_count)
            goto bad_fds;
        *release_fence_fd = received_fds[index++];
    }
    if (index != fd_count)
        goto bad_fds;
    return 0;

bad_fds:
    for (size_t i = 0; i < fd_count; i++)
        close(received_fds[i]);
    *present_fence_fd = -1;
    *release_fence_fd = -1;
    errno = EPROTO;
    return -1;
}
