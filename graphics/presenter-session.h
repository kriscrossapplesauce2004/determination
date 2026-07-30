#pragma once

#include <stddef.h>
#include <stdint.h>

#include "presenter-policy.h"

struct det_presenter_session {
    uint64_t buffers[DET_PRESENTER_MAX_BUFFERS];
    uint64_t buffer_pixels[DET_PRESENTER_MAX_BUFFERS];
    uint64_t serials[DET_PRESENTER_MAX_INFLIGHT_FRAMES];
    uint64_t inflight_buffers[DET_PRESENTER_MAX_INFLIGHT_FRAMES];
    uint64_t registered_pixels;
    size_t buffer_count;
    size_t inflight_count;
};

void det_presenter_session_init(struct det_presenter_session *session);
int det_presenter_session_register(struct det_presenter_session *session,
                                   uint64_t buffer_id, uint32_t width,
                                   uint32_t height);
int det_presenter_session_unregister(struct det_presenter_session *session,
                                     uint64_t buffer_id);
int det_presenter_session_present(struct det_presenter_session *session,
                                  uint64_t serial, uint64_t buffer_id);
int det_presenter_session_complete(struct det_presenter_session *session,
                                   uint64_t serial, uint64_t buffer_id,
                                   uint64_t released_buffer_id);
