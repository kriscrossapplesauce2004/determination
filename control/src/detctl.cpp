#include "determination/control/protocol.hpp"
#include "determination/control/system.hpp"

#include <cerrno>
#include <cstdlib>
#include <chrono>
#include <iostream>
#include <string>
#include <thread>
#include <unistd.h>

using namespace determination::control;

namespace {

struct Options {
    std::string root = "/data/determination";
    std::string socket;
    bool json = false;
    bool wait = false;
    std::uint32_t deadline_ms = 120'000;
    Operation operation = Operation::Status;
    std::string payload;
};

void usage(const char *program)
{
    std::cerr << "usage: " << program << " [--root PATH] [--socket PATH] "
              << "hello|ping|status|doctor|capabilities|metrics|mode [phone|desktop] "
              << "|recover|boot-profile [phone|linux-first]|boot-apply "
                 "[--wait] [--deadline SECONDS] [--json]\n";
}

bool parse(int argc, char **argv, Options *options)
{
    bool command_seen = false;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if ((argument == "--root" || argument == "--socket") && index + 1 < argc) {
            const std::string value = argv[++index];
            if (argument == "--root") options->root = value;
            else options->socket = value;
        } else if (argument == "--json") {
            options->json = true;
        } else if (argument == "--wait") {
            options->wait = true;
        } else if (argument == "--deadline" && index + 1 < argc) {
            char *end = nullptr;
            const unsigned long seconds = std::strtoul(argv[++index], &end, 10);
            if (!end || *end != '\0' || seconds < 5 || seconds > 300) return false;
            options->deadline_ms = static_cast<std::uint32_t>(seconds * 1000UL);
        } else if (!command_seen && argument == "hello") {
            options->operation = Operation::Hello;
            command_seen = true;
        } else if (!command_seen && argument == "ping") {
            options->operation = Operation::Ping;
            command_seen = true;
        } else if (!command_seen && argument == "status") {
            options->operation = Operation::Status;
            command_seen = true;
        } else if (!command_seen && argument == "doctor") {
            options->operation = Operation::Doctor;
            command_seen = true;
        } else if (!command_seen && argument == "capabilities") {
            options->operation = Operation::Capabilities;
            command_seen = true;
        } else if (!command_seen && argument == "metrics") {
            options->operation = Operation::MetricsSnapshot;
            command_seen = true;
        } else if (!command_seen && argument == "mode") {
            command_seen = true;
            if (index + 1 < argc && (std::string(argv[index + 1]) == "phone" ||
                                     std::string(argv[index + 1]) == "desktop")) {
                options->operation = Operation::ModeSet;
                options->payload = argv[++index];
            } else {
                options->operation = Operation::ModeGet;
            }
        } else if (!command_seen && argument == "recover") {
            options->operation = Operation::ModeRecover;
            options->payload = "phone";
            command_seen = true;
        } else if (!command_seen && argument == "boot-profile") {
            command_seen = true;
            if (index + 1 < argc &&
                (std::string(argv[index + 1]) == "phone" ||
                 std::string(argv[index + 1]) == "linux-first")) {
                options->operation = Operation::BootProfileSet;
                options->payload = argv[++index];
            } else {
                options->operation = Operation::BootProfileGet;
            }
        } else if (!command_seen && argument == "boot-apply") {
            options->operation = Operation::BootProfileApply;
            command_seen = true;
        } else {
            usage(argv[0]);
            return false;
        }
    }
    if (!command_seen) return false;
    if (options->root.empty() || options->root.front() != '/') return false;
    if (options->socket.empty()) options->socket = options->root + "/run/detd.sock";
    return true;
}

ReceiveResult transact(const Options &options, Operation operation,
                       const std::string &payload, std::uint64_t request_id,
                       std::string *error)
{
    const int socket = connect_socket(options.socket, error);
    if (socket < 0) {
        ReceiveResult unavailable;
        unavailable.status = Status::Unavailable;
        unavailable.error = *error;
        return unavailable;
    }
    Packet request;
    request.header.operation = static_cast<std::uint32_t>(operation);
    request.header.request_id = request_id;
    request.header.deadline_ms = options.deadline_ms;
    request.payload = payload;
    if (!send_packet(socket, request, error)) {
        close(socket);
        ReceiveResult unavailable;
        unavailable.status = Status::Unavailable;
        unavailable.error = *error;
        return unavailable;
    }
    ReceiveResult response = receive_packet(socket);
    close(socket);
    return response;
}

int exit_code(Status status)
{
    switch (status) {
    case Status::Ok:
    case Status::Accepted: return 0;
    case Status::Rejected: return 3;
    case Status::Unavailable: return 4;
    case Status::DeadlineExceeded: return 5;
    case Status::Busy: return 6;
    case Status::PermissionDenied: return 7;
    case Status::RecoveryRequired: return 8;
    case Status::ProtocolMismatch: return 9;
    case Status::InvalidRequest: return 10;
    case Status::InternalError: return 11;
    }
    return 11;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse(argc, argv, &options)) {
        usage(argv[0]);
        return 2;
    }

    std::string error;
    const std::uint64_t request_id =
        (static_cast<std::uint64_t>(getpid()) << 32U) ^ monotonic_milliseconds();
    ReceiveResult response = transact(options, options.operation, options.payload,
                                      request_id, &error);
    if (!response.ok) {
        std::cerr << "detctl: receive: " << response.error << '\n';
        return exit_code(response.status);
    }
    const Status status = static_cast<Status>(response.packet.header.status);
    const std::string initial_payload = response.packet.payload;
    if (!response.packet.payload.empty() &&
        !(options.wait && status == Status::Accepted)) {
        std::cout << response.packet.payload << '\n';
    }
    if (status != Status::Ok && status != Status::Accepted && !options.json) {
        std::cerr << "detctl: " << status_name(status) << '\n';
    }
    if (status != Status::Accepted || !options.wait ||
        (options.operation != Operation::ModeSet &&
         options.operation != Operation::ModeRecover &&
         options.operation != Operation::BootProfileApply)) {
        return exit_code(status);
    }

    const std::string target = options.operation == Operation::ModeRecover
        ? "phone"
        : (options.operation == Operation::BootProfileApply
            ? (initial_payload.find("\"profile\":\"linux-first\"") !=
                    std::string::npos ? "desktop" : "phone")
            : options.payload);
    const std::string observed = "\"observed\":\"" + target + "\"";
    const std::uint64_t deadline = monotonic_milliseconds() + options.deadline_ms;
    while (monotonic_milliseconds() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        response = transact(options, Operation::ModeGet, {}, request_id, &error);
        if (!response.ok) {
            std::cerr << "detctl: wait status: " << response.error << '\n';
            return exit_code(response.status);
        }
        const std::string &payload = response.packet.payload;
        if (payload.find(observed) != std::string::npos &&
            payload.find("\"step\":\"idle\"") != std::string::npos) {
            std::cout << payload << '\n';
            return 0;
        }
        if (payload.find("\"observed\":\"recovery\"") != std::string::npos) {
            std::cout << payload << '\n';
            return exit_code(Status::RecoveryRequired);
        }
        if (payload.find("\"step\":\"rollback-complete\"") != std::string::npos ||
            payload.find("\"step\":\"failed-phone-safe\"") != std::string::npos) {
            std::cout << payload << '\n';
            return exit_code(Status::InternalError);
        }
    }
    std::cerr << "detctl: transition wait deadline exceeded\n";
    return exit_code(Status::DeadlineExceeded);
}
