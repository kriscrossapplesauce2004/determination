#include <assert.h>
#include <stdint.h>
#include <string.h>

#include "presenter-protocol.h"
#include "presenter-policy.h"
#include "presenter-session.h"

int main(void)
{
    struct det_presenter_packet packet =
        det_presenter_packet_init(DET_PRESENTER_PRESENT);

    assert(sizeof(packet) == 96);
    assert(packet.magic == DET_PRESENTER_MAGIC);
    assert(packet.version == DET_PRESENTER_VERSION);
    assert(packet.size == sizeof(packet));
    assert(packet.op == DET_PRESENTER_PRESENT);
    assert(packet.flags == 0);
    assert(packet.serial == 0);

    assert(det_presenter_dimensions_valid(1920, 1080));
    assert(!det_presenter_dimensions_valid(0, 1080));
    assert(!det_presenter_dimensions_valid(8193, 1080));
    assert(det_presenter_present_flags_valid(0));
    assert(det_presenter_present_flags_valid(DET_PRESENTER_HAS_ACQUIRE_FENCE));
    assert(!det_presenter_present_flags_valid(DET_PRESENTER_HAS_RELEASE_FENCE));
    assert(det_presenter_completion_flags_valid(
        DET_PRESENTER_HAS_PRESENT_FENCE | DET_PRESENTER_HAS_RELEASE_FENCE));
    assert(!det_presenter_completion_flags_valid(
        DET_PRESENTER_HAS_ACQUIRE_FENCE));

    struct det_presenter_session session;
    det_presenter_session_init(&session);
    assert(det_presenter_session_register(&session, 1, 1920, 1080) == 0);
    assert(det_presenter_session_register(&session, 1, 1920, 1080) == -1);
    for (uint64_t id = 2; id <= DET_PRESENTER_MAX_BUFFERS; ++id)
        assert(det_presenter_session_register(&session, id, 1, 1) == 0);
    assert(det_presenter_session_register(&session, 99, 1, 1) == -1);
    assert(det_presenter_session_present(&session, 7, 1) == 0);
    assert(det_presenter_session_present(&session, 7, 1) == -1);
    assert(det_presenter_session_unregister(&session, 1) == -1);
    assert(det_presenter_session_complete(&session, 8, 1, 0) == -1);
    assert(det_presenter_session_complete(&session, 7, 1, 2) == 0);
    assert(det_presenter_session_unregister(&session, 1) == 0);
    return 0;
}
