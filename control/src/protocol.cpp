#include "determination/control/protocol.hpp"

#include <cerrno>
#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

namespace determination::control {

bool send_packet(int fd, const Packet &packet, std::string *error)
{
    if (packet.payload.size() > kMaximumPayload) {
        if (error) *error = "payload exceeds protocol limit";
        errno = EMSGSIZE;
        return false;
    }

    PacketHeader header = packet.header;
    header.magic = kProtocolMagic;
    header.major = kProtocolMajor;
    header.minor = kProtocolMinor;
    header.header_size = sizeof(PacketHeader);
    header.payload_size = static_cast<std::uint32_t>(packet.payload.size());

    iovec vectors[2] = {
        {.iov_base = &header, .iov_len = sizeof(header)},
        {.iov_base = const_cast<char *>(packet.payload.data()),
         .iov_len = packet.payload.size()},
    };
    msghdr message{};
    message.msg_iov = vectors;
    message.msg_iovlen = packet.payload.empty() ? 1U : 2U;

    const auto expected = static_cast<ssize_t>(sizeof(header) + packet.payload.size());
    ssize_t sent;
    do {
        sent = sendmsg(fd, &message, MSG_NOSIGNAL);
    } while (sent < 0 && errno == EINTR);
    if (sent != expected) {
        if (error) {
            *error = sent < 0 ? std::strerror(errno) : "short packet send";
        }
        return false;
    }
    return true;
}

ReceiveResult receive_packet(int fd)
{
    ReceiveResult result;
    std::vector<std::byte> bytes(sizeof(PacketHeader) + kMaximumPayload);
    iovec vector{.iov_base = bytes.data(), .iov_len = bytes.size()};
    msghdr message{};
    message.msg_iov = &vector;
    message.msg_iovlen = 1;

    ssize_t received;
    do {
        received = recvmsg(fd, &message, MSG_CMSG_CLOEXEC);
    } while (received < 0 && errno == EINTR);
    if (received < 0) {
        result.status = Status::Unavailable;
        result.error = std::strerror(errno);
        return result;
    }
    if (received == 0) {
        result.status = Status::Unavailable;
        result.error = "peer closed the socket";
        return result;
    }
    if ((message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) != 0 ||
        received < static_cast<ssize_t>(sizeof(PacketHeader))) {
        result.status = Status::InvalidRequest;
        result.error = "truncated control packet";
        return result;
    }

    std::memcpy(&result.packet.header, bytes.data(), sizeof(PacketHeader));
    const PacketHeader &header = result.packet.header;
    if (header.magic != kProtocolMagic || header.header_size != sizeof(PacketHeader)) {
        result.status = Status::InvalidRequest;
        result.error = "invalid protocol header";
        return result;
    }
    if (header.major != kProtocolMajor) {
        result.status = Status::ProtocolMismatch;
        result.error = "protocol major mismatch";
        return result;
    }
    if (header.payload_size > kMaximumPayload ||
        static_cast<std::size_t>(received) != sizeof(PacketHeader) + header.payload_size) {
        result.status = Status::InvalidRequest;
        result.error = "invalid payload size";
        return result;
    }
    const auto *payload = reinterpret_cast<const char *>(bytes.data() + sizeof(PacketHeader));
    result.packet.payload.assign(payload, header.payload_size);
    result.status = Status::Ok;
    result.ok = true;
    return result;
}

int connect_socket(const std::string &path, std::string *error)
{
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (path.empty() || path.size() >= sizeof(address.sun_path)) {
        if (error) *error = "socket path is too long";
        errno = ENAMETOOLONG;
        return -1;
    }
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1U);
    const int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        if (error) *error = std::strerror(errno);
        return -1;
    }
    if (connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
        if (error) *error = std::strerror(errno);
        close(fd);
        return -1;
    }
    return fd;
}

std::string operation_name(Operation operation)
{
    switch (operation) {
    case Operation::Hello: return "hello";
    case Operation::Ping: return "ping";
    case Operation::Status: return "status";
    case Operation::Doctor: return "doctor";
    case Operation::Capabilities: return "capabilities";
    case Operation::ModeGet: return "mode-get";
    case Operation::ModeSet: return "mode-set";
    case Operation::ModeRecover: return "mode-recover";
    case Operation::GuestReport: return "guest-report";
    }
    return "unknown";
}

std::string status_name(Status status)
{
    switch (status) {
    case Status::Ok: return "ok";
    case Status::Accepted: return "accepted";
    case Status::Rejected: return "rejected";
    case Status::Unavailable: return "unavailable";
    case Status::DeadlineExceeded: return "deadline-exceeded";
    case Status::Busy: return "busy";
    case Status::ProtocolMismatch: return "protocol-mismatch";
    case Status::InvalidRequest: return "invalid-request";
    case Status::PermissionDenied: return "permission-denied";
    case Status::RecoveryRequired: return "recovery-required";
    case Status::InternalError: return "internal-error";
    }
    return "unknown";
}

} // namespace determination::control
