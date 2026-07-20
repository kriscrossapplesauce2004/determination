#pragma once

/*
 * Determination zero-copy presenter protocol.
 *
 * The control packets travel over AF_UNIX SOCK_SEQPACKET. REGISTER is followed
 * by one AHardwareBuffer_sendHandleToUnixSocket() message. PRESENT optionally
 * carries one acquire sync_file fd. COMPLETE optionally carries present and
 * previous-buffer release sync_file fds, in that order according to flags.
 */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DET_PRESENTER_MAGIC 0x44545031u /* "DTP1" */
#define DET_PRESENTER_VERSION 1u

enum det_presenter_op {
    DET_PRESENTER_REGISTER = 1,
    DET_PRESENTER_PRESENT = 2,
    DET_PRESENTER_UNREGISTER = 3,
};

/* Response opcodes use the high bit and do not fit a pre-C23 enum's int. */
#define DET_PRESENTER_COMPLETE UINT32_C(0x80000002)
#define DET_PRESENTER_ERROR UINT32_C(0x800000ff)

enum det_presenter_flags {
    DET_PRESENTER_HAS_ACQUIRE_FENCE = 1u << 0,
    DET_PRESENTER_HAS_PRESENT_FENCE = 1u << 1,
    DET_PRESENTER_HAS_RELEASE_FENCE = 1u << 2,
};

struct det_presenter_packet {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t op;
    uint32_t flags;
    uint64_t serial;
    uint64_t buffer_id;
    uint64_t released_buffer_id;
    uint64_t desired_present_time_ns;
    int64_t latch_time_ns;
    int64_t callback_time_ns;
    uint32_t width;
    uint32_t height;
    uint32_t format;
    uint32_t stride;
    uint64_t usage;
    int32_t status;
    uint32_t reserved;
};

#ifdef __cplusplus
static_assert(sizeof(det_presenter_packet) == 96,
              "presenter protocol layout changed");
#else
_Static_assert(sizeof(struct det_presenter_packet) == 96,
               "presenter protocol layout changed");
#endif

static inline struct det_presenter_packet det_presenter_packet_init(uint32_t op)
{
#ifdef __cplusplus
    struct det_presenter_packet packet{};
#else
    struct det_presenter_packet packet = {0};
#endif
    packet.magic = DET_PRESENTER_MAGIC;
    packet.version = DET_PRESENTER_VERSION;
    packet.size = (uint16_t)sizeof(packet);
    packet.op = op;
    return packet;
}

#ifdef __cplusplus
}
#endif
