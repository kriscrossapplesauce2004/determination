#include "determination/control/policy.hpp"

namespace determination::control {

bool endpoint_peer_allowed(Endpoint endpoint, uid_t uid)
{
    if (endpoint == Endpoint::Admin) return uid == 0 || uid == 1000;
    return uid == 0 || uid == 1000;
}

bool mode_request_allowed(Endpoint endpoint, uid_t uid, Mode target)
{
    if (endpoint == Endpoint::Admin) return uid == 0;
    return (uid == 0 || uid == 1000) && target == Mode::Phone;
}

bool recovery_request_allowed(Endpoint endpoint, uid_t uid)
{
    if (endpoint == Endpoint::Admin) return uid == 0;
    return uid == 0 || uid == 1000;
}

bool guest_report_allowed(Endpoint endpoint, uid_t uid)
{
    return endpoint == Endpoint::Guest && (uid == 0 || uid == 1000);
}

} // namespace determination::control
