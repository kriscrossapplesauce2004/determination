#include "determination/control/protocol.hpp"
#include "determination/control/system.hpp"

#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <poll.h>
#include <sstream>
#include <string>
#include <unistd.h>

using namespace determination::control;

namespace {

std::atomic<bool> running{true};

void stop_agent(int)
{
    running.store(false);
}

struct Options {
    std::string socket = "/mnt/det-control/detd.sock";
    std::string command;
    std::string action;
    bool json = false;
};

void usage(const char *program)
{
    std::cerr << "usage: " << program
              << " [--socket PATH] ping|status|doctor|report|serve|"
                 "signal exit|recover [--json]\n";
}

bool parse(int argc, char **argv, Options *options)
{
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--socket" && index + 1 < argc) {
            options->socket = argv[++index];
        } else if (argument == "--json") {
            options->json = true;
        } else if (options->command.empty()) {
            options->command = argument;
        } else if (options->action.empty()) {
            options->action = argument;
        } else {
            return false;
        }
    }
    if (options->command.empty()) return false;
    if (options->command == "signal") return options->action == "exit";
    return options->action.empty();
}

ReceiveResult request(const Options &options, Operation operation,
                      const std::string &payload, std::uint32_t deadline_ms)
{
    std::string error;
    const int socket = connect_socket(options.socket, &error);
    if (socket < 0) {
        ReceiveResult unavailable;
        unavailable.status = Status::Unavailable;
        unavailable.error = error;
        return unavailable;
    }
    Packet packet;
    packet.header.operation = static_cast<std::uint32_t>(operation);
    packet.header.request_id =
        (static_cast<std::uint64_t>(getpid()) << 32U) ^ monotonic_milliseconds();
    packet.header.deadline_ms = deadline_ms;
    packet.payload = payload;
    if (!send_packet(socket, packet, &error)) {
        close(socket);
        ReceiveResult unavailable;
        unavailable.status = Status::Unavailable;
        unavailable.error = error;
        return unavailable;
    }
    ReceiveResult response = receive_packet(socket);
    close(socket);
    return response;
}

std::string process_json(const std::map<std::string, char> &states,
                         const std::string &name)
{
    const auto found = states.find(name);
    const char state = found == states.end() ? '?' : found->second;
    return state == '-' ? "null" : std::string("\"") + state + '"';
}

std::string report_payload()
{
    const auto processes = process_states(
        {"phoc", "phosh", "pipewire", "wireplumber", "seatd"});
    std::ostringstream output;
    output << "{\"schema\":1,\"boot_id\":\"" << json_escape(boot_id()) << '"'
           << ",\"monotonic_ms\":" << monotonic_milliseconds()
           << ",\"uid\":" << getuid()
           << ",\"wayland\":"
           << (path_exists("/run/user/1000/wayland-0") ? "true" : "false")
           << ",\"session_bus\":"
           << (path_exists("/run/user/1000/bus") ? "true" : "false")
           << ",\"processes\":{\"phoc\":" << process_json(processes, "phoc")
           << ",\"phosh\":" << process_json(processes, "phosh")
           << ",\"pipewire\":" << process_json(processes, "pipewire")
           << ",\"wireplumber\":" << process_json(processes, "wireplumber")
           << ",\"seatd\":" << process_json(processes, "seatd") << '}'
           << ",\"memory_pressure\":\""
           << json_escape(trim(read_file("/proc/pressure/memory", 4096))) << "\"}"
           ;
    return output.str();
}

int status_exit(Status status)
{
    if (status == Status::Ok || status == Status::Accepted) return 0;
    if (status == Status::Unavailable) return 4;
    if (status == Status::PermissionDenied) return 7;
    if (status == Status::RecoveryRequired) return 8;
    return 3;
}

int print_response(const ReceiveResult &response)
{
    if (!response.ok) {
        std::cerr << "det-guest-agent: " << response.error << '\n';
        return status_exit(response.status);
    }
    if (!response.packet.payload.empty()) std::cout << response.packet.payload << '\n';
    return status_exit(static_cast<Status>(response.packet.header.status));
}

int serve(const Options &options)
{
    struct sigaction action{};
    action.sa_handler = stop_agent;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, nullptr);
    sigaction(SIGINT, &action, nullptr);
    signal(SIGPIPE, SIG_IGN);

    std::uint64_t failures = 0;
    while (running.load()) {
        const ReceiveResult response = request(
            options, Operation::GuestReport, report_payload(), 5000);
        if (!response.ok ||
            static_cast<Status>(response.packet.header.status) != Status::Ok) {
            ++failures;
            if (failures == 1 || failures % 6 == 0) {
                std::cerr << "det-guest-agent: report failed x" << failures;
                if (!response.error.empty()) std::cerr << ": " << response.error;
                std::cerr << '\n';
            }
        } else {
            failures = 0;
        }
        poll(nullptr, 0, 10'000);
    }
    return 0;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse(argc, argv, &options)) {
        usage(argv[0]);
        return 2;
    }
    if (options.command == "serve") return serve(options);
    if (options.command == "ping") {
        return print_response(request(options, Operation::Ping, {}, 5000));
    }
    if (options.command == "status") {
        return print_response(request(options, Operation::Status, {}, 5000));
    }
    if (options.command == "doctor") {
        return print_response(request(options, Operation::Doctor, {}, 5000));
    }
    if (options.command == "report") {
        return print_response(request(
            options, Operation::GuestReport, report_payload(), 5000));
    }
    if (options.command == "signal") {
        return print_response(request(
            options, Operation::ModeSet, "phone", 120'000));
    }
    if (options.command == "recover") {
        return print_response(request(
            options, Operation::ModeRecover, "phone", 120'000));
    }
    usage(argv[0]);
    return 2;
}
