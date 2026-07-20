#include "determination/control/protocol.hpp"
#include "determination/control/system.hpp"

#include <cerrno>
#include <cstdlib>
#include <iostream>
#include <string>
#include <unistd.h>

using namespace determination::control;

namespace {

struct Options {
    std::string root = "/data/determination";
    std::string socket;
    bool json = false;
    Operation operation = Operation::Status;
    std::string payload;
};

void usage(const char *program)
{
    std::cerr << "usage: " << program << " [--root PATH] [--socket PATH] "
              << "hello|ping|status|doctor|capabilities|mode [phone|desktop] "
              << "[--json]\n";
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
        } else if (!command_seen && argument == "mode") {
            command_seen = true;
            if (index + 1 < argc && (std::string(argv[index + 1]) == "phone" ||
                                     std::string(argv[index + 1]) == "desktop")) {
                options->operation = Operation::ModeSet;
                options->payload = argv[++index];
            } else {
                options->operation = Operation::ModeGet;
            }
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
    const int socket = connect_socket(options.socket, &error);
    if (socket < 0) {
        std::cerr << "detctl: connect " << options.socket << ": " << error << '\n';
        return exit_code(Status::Unavailable);
    }
    Packet request;
    request.header.operation = static_cast<std::uint32_t>(options.operation);
    request.header.request_id =
        (static_cast<std::uint64_t>(getpid()) << 32U) ^ monotonic_milliseconds();
    request.header.deadline_ms = 15'000;
    request.payload = options.payload;
    if (!send_packet(socket, request, &error)) {
        std::cerr << "detctl: send: " << error << '\n';
        close(socket);
        return exit_code(Status::Unavailable);
    }
    const ReceiveResult response = receive_packet(socket);
    close(socket);
    if (!response.ok) {
        std::cerr << "detctl: receive: " << response.error << '\n';
        return exit_code(response.status);
    }
    const Status status = static_cast<Status>(response.packet.header.status);
    if (!response.packet.payload.empty()) {
        std::cout << response.packet.payload << '\n';
    }
    if (status != Status::Ok && status != Status::Accepted && !options.json) {
        std::cerr << "detctl: " << status_name(status) << '\n';
    }
    return exit_code(status);
}

