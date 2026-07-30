#include "presenter-session.h"

#include <errno.h>
#include <string.h>

static size_t find_id(const uint64_t *ids, size_t count, uint64_t id)
{
    for (size_t index = 0; index < count; ++index) {
        if (ids[index] == id) return index;
    }
    return count;
}

void det_presenter_session_init(struct det_presenter_session *session)
{
    memset(session, 0, sizeof(*session));
}

int det_presenter_session_register(struct det_presenter_session *session,
                                   uint64_t buffer_id, uint32_t width,
                                   uint32_t height)
{
    const uint64_t pixels = (uint64_t)width * height;
    if (!session || buffer_id == 0 || !det_presenter_dimensions_valid(width, height) ||
        session->buffer_count >= DET_PRESENTER_MAX_BUFFERS ||
        find_id(session->buffers, session->buffer_count, buffer_id) != session->buffer_count ||
        pixels > DET_PRESENTER_MAX_REGISTERED_PIXELS - session->registered_pixels) {
        errno = EINVAL;
        return -1;
    }
    session->buffers[session->buffer_count++] = buffer_id;
    session->buffer_pixels[session->buffer_count - 1U] = pixels;
    session->registered_pixels += pixels;
    return 0;
}

int det_presenter_session_unregister(struct det_presenter_session *session,
                                     uint64_t buffer_id)
{
    if (!session) { errno = EINVAL; return -1; }
    const size_t index = find_id(session->buffers, session->buffer_count, buffer_id);
    if (index == session->buffer_count ||
        find_id(session->inflight_buffers, session->inflight_count, buffer_id) !=
            session->inflight_count) {
        errno = EBUSY;
        return -1;
    }
    session->registered_pixels -= session->buffer_pixels[index];
    --session->buffer_count;
    session->buffers[index] = session->buffers[session->buffer_count];
    session->buffer_pixels[index] = session->buffer_pixels[session->buffer_count];
    return 0;
}

int det_presenter_session_present(struct det_presenter_session *session,
                                  uint64_t serial, uint64_t buffer_id)
{
    if (!session || serial == 0 ||
        find_id(session->buffers, session->buffer_count, buffer_id) == session->buffer_count ||
        session->inflight_count >= DET_PRESENTER_MAX_INFLIGHT_FRAMES ||
        find_id(session->serials, session->inflight_count, serial) != session->inflight_count) {
        errno = EINVAL;
        return -1;
    }
    session->serials[session->inflight_count++] = serial;
    session->inflight_buffers[session->inflight_count - 1U] = buffer_id;
    return 0;
}

int det_presenter_session_complete(struct det_presenter_session *session,
                                   uint64_t serial, uint64_t buffer_id,
                                   uint64_t released_buffer_id)
{
    if (!session ||
        find_id(session->buffers, session->buffer_count, buffer_id) == session->buffer_count ||
        (released_buffer_id != 0 &&
         find_id(session->buffers, session->buffer_count, released_buffer_id) == session->buffer_count)) {
        errno = EPROTO;
        return -1;
    }
    const size_t index = find_id(session->serials, session->inflight_count, serial);
    if (index == session->inflight_count ||
        session->inflight_buffers[index] != buffer_id) { errno = EPROTO; return -1; }
    session->serials[index] = session->serials[--session->inflight_count];
    session->inflight_buffers[index] = session->inflight_buffers[session->inflight_count];
    return 0;
}
