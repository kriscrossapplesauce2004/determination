#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace determination::control {

constexpr std::uint32_t kProtocolMagic = 0x44544331U; // DTC1
constexpr std::uint16_t kProtocolMajor = 1;
constexpr std::uint16_t kProtocolMinor = 0;
constexpr std::size_t kMaximumPayload = 16U * 1024U;
constexpr std::uint16_t kFlagResponse = 1U << 0;

enum class Operation : std::uint32_t {
    Hello = 1,
    Ping = 2,
    Status = 3,
    Doctor = 4,
    Capabilities = 5,
    ModeGet = 0x100,
    ModeSet = 0x101,
    ModeRecover = 0x102,
    GuestReport = 0x200,
};

enum class Status : std::int32_t {
    Ok = 0,
    Accepted = 1,
    Rejected = -1,
    Unavailable = -2,
    DeadlineExceeded = -3,
    Busy = -4,
    ProtocolMismatch = -5,
    InvalidRequest = -6,
    PermissionDenied = -7,
    RecoveryRequired = -8,
    InternalError = -9,
};

struct PacketHeader {
    std::uint32_t magic = kProtocolMagic;
    std::uint16_t major = kProtocolMajor;
    std::uint16_t minor = kProtocolMinor;
    std::uint16_t header_size = sizeof(PacketHeader);
    std::uint16_t flags = 0;
    std::uint32_t operation = 0;
    std::int32_t status = 0;
    std::uint32_t payload_size = 0;
    std::uint64_t request_id = 0;
    std::uint64_t generation = 0;
    std::uint32_t deadline_ms = 0;
    std::uint32_t reserved = 0;
};

static_assert(sizeof(PacketHeader) == 48);

struct Packet {
    PacketHeader header;
    std::string payload;
};

struct ReceiveResult {
    bool ok = false;
    Status status = Status::InternalError;
    std::string error;
    Packet packet;
};

bool send_packet(int fd, const Packet &packet, std::string *error);
ReceiveResult receive_packet(int fd);
int connect_socket(const std::string &path, std::string *error);
std::string operation_name(Operation operation);
std::string status_name(Status status);

} // namespace determination::control
