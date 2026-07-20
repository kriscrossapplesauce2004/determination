#include <assert.h>
#include <stdint.h>
#include <string.h>

#include "presenter-protocol.h"
#include "presenter-policy.h"

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
    return 0;
}
