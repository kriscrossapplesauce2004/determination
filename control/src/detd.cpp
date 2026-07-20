#include "determination/control/protocol.hpp"
#include "determination/control/policy.hpp"
#include "determination/control/state.hpp"
#include "determination/control/system.hpp"
#include "determination/control/transition.hpp"

#include <atomic>
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <poll.h>
#include <sstream>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/un.h>
#include <unistd.h>

using namespace determination::control;

namespace {

std::atomic<bool> running{true};

void handle_signal(int)
{
    running.store(false);
}

struct Options {
    std::string root = "/data/determination";
    std::string socket;
    bool observe_only = true;
};

void usage(const char *program)
{
    std::cerr << "usage: " << program
              << " [--root PATH] [--socket PATH] [--foreground] "
                 "[--observe-only|--allow-transitions]\n";
}

bool parse_options(int argc, char **argv, Options *options)
{
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if ((argument == "--root" || argument == "--socket") && index + 1 < argc) {
            const std::string value = argv[++index];
            if (argument == "--root") options->root = value;
            else options->socket = value;
        } else if (argument == "--foreground" || argument == "--observe-only") {
            options->observe_only = true;
        } else if (argument == "--allow-transitions") {
            options->observe_only = false;
        } else if (argument == "--help") {
            usage(argv[0]);
            return false;
        } else {
            usage(argv[0]);
            return false;
        }
    }
    if (options->root.empty() || options->root.front() != '/') return false;
    if (options->socket.empty()) options->socket = options->root + "/run/detd.sock";
    return true;
}

Mode observed_mode(const std::string &root)
{
    return path_exists(root + "/run/desktop-mode") ? Mode::Desktop : Mode::Phone;
}

std::string memory_value(const std::string &key)
{
    std::istringstream lines(read_file("/proc/meminfo", 16U * 1024U));
    std::string line;
    while (std::getline(lines, line)) {
        if (line.rfind(key + ':', 0) == 0) return trim(line.substr(key.size() + 1U));
    }
    return {};
}

std::string process_state_json(const std::string &name)
{
    const char state = process_state(name);
    return state == '-' ? "null" : std::string("\"") + state + '"';
}

std::string config_value(const std::string &config, const std::string &key)
{
    std::istringstream lines(config);
    std::string line;
    const std::string prefix = key + '=';
    std::string result;
    while (std::getline(lines, line)) {
        if (line.rfind(prefix, 0) == 0) result = trim(line.substr(prefix.size()));
    }
    if (result.size() >= 2 &&
        ((result.front() == '"' && result.back() == '"') ||
         (result.front() == '\'' && result.back() == '\''))) {
        result = result.substr(1, result.size() - 2U);
    }
    return result;
}

std::string human_bytes(std::uint64_t bytes)
{
    static constexpr const char *suffixes[] = {"B", "K", "M", "G", "T"};
    std::size_t suffix = 0;
    double value = static_cast<double>(bytes);
    constexpr std::size_t suffix_count = sizeof(suffixes) / sizeof(suffixes[0]);
    while (value >= 1024.0 && suffix + 1U < suffix_count) {
        value /= 1024.0;
        ++suffix;
    }
    std::ostringstream output;
    output.setf(std::ios::fixed);
    output.precision(suffix >= 3U ? 1 : 0);
    output << value << suffixes[suffix];
    return output.str();
}

std::string data_free()
{
    struct statvfs status{};
    if (statvfs("/data", &status) != 0) return {};
    return human_bytes(static_cast<std::uint64_t>(status.f_bavail) * status.f_frsize);
}

std::string uptime_text()
{
    const std::string uptime = read_file("/proc/uptime", 128);
    if (uptime.empty()) return {};
    const std::uint64_t seconds = std::strtoull(uptime.c_str(), nullptr, 10);
    return std::to_string(seconds / 3600U) + "h " +
           std::to_string((seconds % 3600U) / 60U) + "m";
}

std::string guest_state(const std::string &root)
{
    const std::string command = root + "/run/lxc/guest/command";
    if (path_exists(command)) return "running";
    if (process_state("lxc-start") != '-') return "running";
    return "stopped";
}

std::string status_payload(const Options &options, const StateRecord &state)
{
    const std::string sf = android_property("init.svc.surfaceflinger");
    const std::string profile = read_file(options.root + "/etc/device.conf");
    std::string gauge = config_value(profile, "DET_BATTERY_GAUGE");
    if (gauge.empty()) gauge = "battery";
    const std::string battery_root = "/sys/class/power_supply/" + gauge;
    const std::string voltage = trim(read_file(battery_root + "/voltage_now", 64));
    std::uint64_t millivolts = std::strtoull(voltage.c_str(), nullptr, 10) / 1000U;
    const Mode live = observed_mode(options.root);
    const std::string guest_report = trim(
        read_file(options.root + "/run/guest-health.json", 8192));
    std::ostringstream output;
    output << "{\"protocol\":\"1.0\""
           << ",\"observe_only\":" << (options.observe_only ? "true" : "false")
           << ",\"state\":" << state_json(state)
           << ",\"live_observed\":\"" << mode_name(observed_mode(options.root)) << '"'
           << ",\"surfaceflinger\":\"" << json_escape(sf.empty() ? "unknown" : sf) << '"'
           << ",\"processes\":{\"system_server\":" << process_state_json("system_server")
           << ",\"phoc\":" << process_state_json("phoc")
           << ",\"phosh\":" << process_state_json("phosh") << '}'
           << ",\"memory\":{\"available\":\"" << json_escape(memory_value("MemAvailable"))
           << "\",\"swap_free\":\"" << json_escape(memory_value("SwapFree")) << "\"}"
           << ",\"guest_report\":"
           << (guest_report.empty()
                   ? "null"
                   : std::string("\"") + json_escape(guest_report) + '"')
           << ",\"profile_digest\":\"" << std::hex << fnv1a64(profile) << std::dec << '"'
           << ",\"compat\":{\"uid\":\"0\",\"kernel\":\""
           << json_escape(trim(read_file("/proc/sys/kernel/osrelease", 256)))
           << "\",\"sf\":\"" << json_escape(sf.empty() ? "unknown" : sf)
           << "\",\"mode\":\"" << mode_name(live)
           << "\",\"guest\":\"" << guest_state(options.root)
           << "\",\"agent\":\""
           << (path_exists(options.root + "/run/hostagent.pid") ? "up" : "down")
           << "\",\"installed\":\""
           << (path_exists(options.root + "/bin/desktop-on") ? "yes" : "no")
           << "\",\"ip\":\"\",\"batt\":\""
           << json_escape(trim(read_file(battery_root + "/capacity", 64)))
           << "\",\"battmv\":\"" << millivolts
           << "\",\"battstat\":\""
           << json_escape(trim(read_file("/sys/class/power_supply/battery/status", 64)))
           << "\",\"uptime\":\"" << uptime_text()
           << "\",\"datafree\":\"" << data_free() << "\"}}"
           ;
    return output.str();
}

std::string doctor_payload(const Options &options, const StateRecord &state)
{
    const bool marker = path_exists(options.root + "/run/desktop-mode");
    const bool mismatch = marker != (state.observed == Mode::Desktop);
    const bool recovery = state.observed == Mode::Recovery;
    const bool stable = state.observed == Mode::Phone || state.observed == Mode::Desktop;
    const bool guest_tools = path_exists(options.root + "/lxc/bin/lxc-info");
    const bool emergency = path_exists(options.root + "/bin/desktop-off");
    std::ostringstream output;
    output << "{\"healthy\":"
           << (!mismatch && !recovery && stable && emergency ? "true" : "false")
           << ",\"state\":" << state_json(state)
           << ",\"checks\":{\"state_marker_consistent\":" << (!mismatch ? "true" : "false")
           << ",\"emergency_phone_restore\":" << (emergency ? "true" : "false")
           << ",\"guest_tools\":" << (guest_tools ? "true" : "false")
           << ",\"binderfs\":" << (path_exists("/dev/binderfs") ? "true" : "false")
           << ",\"pid_namespace\":" << (path_exists("/proc/self/ns/pid") ? "true" : "false")
           << "},\"memory_pressure\":\""
           << json_escape(trim(read_file("/proc/pressure/memory", 4096))) << "\"}"
           ;
    return output.str();
}

Packet response_for(const Packet &request, const Options &options,
                    TransitionController *controller, uid_t peer_uid,
                    bool guest_endpoint)
{
    const Endpoint endpoint = guest_endpoint ? Endpoint::Guest : Endpoint::Admin;
    const StateRecord state = controller->snapshot();
    Packet response;
    response.header.operation = request.header.operation;
    response.header.flags = kFlagResponse;
    response.header.request_id = request.header.request_id;
    response.header.generation = state.generation;
    response.header.status = static_cast<std::int32_t>(Status::Ok);
    const auto operation = static_cast<Operation>(request.header.operation);
    switch (operation) {
    case Operation::Hello:
        response.payload = "{\"service\":\"detd\",\"protocol_major\":1,"
                           "\"protocol_minor\":0,\"observe_only\":" +
                           std::string(options.observe_only ? "true" : "false") + "}";
        break;
    case Operation::Ping:
        response.payload = "{\"ok\":true}";
        break;
    case Operation::Status:
    case Operation::ModeGet:
        response.payload = status_payload(options, state);
        break;
    case Operation::Doctor:
        response.payload = doctor_payload(options, state);
        break;
    case Operation::Capabilities:
        response.payload = "{\"operations\":[\"hello\",\"ping\",\"status\","
                           "\"doctor\",\"capabilities\",\"mode-get\","
                           "\"mode-set\",\"mode-recover\",\"guest-report\"],"
                           "\"guest_endpoint\":" +
                           std::string(guest_endpoint ? "true" : "false") +
                           ",\"transitions\":" +
                           std::string(options.observe_only ? "false" : "true") +
                           ",\"structured_state\":true,"
                           "\"authenticated_peer_credentials\":true}";
        break;
    case Operation::ModeSet: {
        const Mode target = parse_mode(request.payload);
        if (!mode_request_allowed(endpoint, peer_uid, target)) {
            response.header.status = static_cast<std::int32_t>(Status::PermissionDenied);
            response.payload = "{\"error\":\"mutating operation requires root peer\"}";
            break;
        }
        const TransitionRequestResult transition = controller->request(
            target, request.header.request_id, request.header.deadline_ms);
        response.header.status = static_cast<std::int32_t>(transition.status);
        response.header.generation = transition.state.generation;
        response.payload = "{\"message\":\"" + json_escape(transition.message) +
                           "\",\"state\":" + state_json(transition.state) + "}";
        break;
    }
    case Operation::ModeRecover: {
        if (!recovery_request_allowed(endpoint, peer_uid)) {
            response.header.status = static_cast<std::int32_t>(Status::PermissionDenied);
            response.payload = "{\"error\":\"recovery requires root peer\"}";
            break;
        }
        const TransitionRequestResult transition = controller->request(
            Mode::Phone, request.header.request_id, request.header.deadline_ms);
        response.header.status = static_cast<std::int32_t>(transition.status);
        response.header.generation = transition.state.generation;
        response.payload = "{\"message\":\"" + json_escape(transition.message) +
                           "\",\"state\":" + state_json(transition.state) + "}";
        break;
    }
    case Operation::GuestReport: {
        if (!guest_report_allowed(endpoint, peer_uid)) {
            response.header.status = static_cast<std::int32_t>(Status::PermissionDenied);
            response.payload = "{\"error\":\"guest report requires guest endpoint\"}";
            break;
        }
        if (request.payload.size() > 8192U || request.payload.size() < 2U ||
            request.payload.front() != '{' || request.payload.back() != '}') {
            response.header.status = static_cast<std::int32_t>(Status::InvalidRequest);
            response.payload = "{\"error\":\"invalid guest report\"}";
            break;
        }
        std::string write_error;
        if (!atomic_write_file(options.root + "/run/guest-health.json",
                               request.payload + "\n", 0640, &write_error)) {
            response.header.status = static_cast<std::int32_t>(Status::InternalError);
            response.payload = "{\"error\":\"" + json_escape(write_error) + "\"}";
            break;
        }
        response.payload = "{\"ok\":true}";
        break;
    }
    default:
        response.header.status = static_cast<std::int32_t>(Status::InvalidRequest);
        response.payload = "{\"error\":\"unknown operation\"}";
        break;
    }
    return response;
}

int create_server(const std::string &path, gid_t group, std::string *error)
{
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path)) {
        *error = "socket path too long";
        return -1;
    }
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1U);
    unlink(path.c_str());
    const int server = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (server < 0) {
        *error = std::strerror(errno);
        return -1;
    }
    const mode_t previous = umask(0077);
    const int bound = bind(server, reinterpret_cast<sockaddr *>(&address), sizeof(address));
    umask(previous);
    if (bound != 0 || chmod(path.c_str(), 0660) != 0 || listen(server, 8) != 0) {
        *error = std::strerror(errno);
        close(server);
        unlink(path.c_str());
        return -1;
    }
#ifdef __ANDROID__
    if (getuid() == 0) chown(path.c_str(), 0, group);
#else
    (void)group;
#endif
    return server;
}

} // namespace

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options)) return 2;

    std::string error;
    if (!ensure_directory(options.root + "/run", 0750, &error) ||
        !ensure_directory(options.root + "/run/control", 0770, &error) ||
        !ensure_directory(options.root + "/state", 0750, &error)) {
        std::cerr << "detd: create state directories: " << error << '\n';
        return 1;
    }

    const std::string lock_path = options.root + "/run/detd.lock";
    const int lock = open(lock_path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0640);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) {
        std::cerr << "detd: another instance owns " << lock_path << '\n';
        if (lock >= 0) close(lock);
        return 1;
    }

    TransitionController controller(options.root, !options.observe_only);
    if (!controller.initialise(&error)) {
        std::cerr << "detd: initialise state: " << error << '\n';
        close(lock);
        return 1;
    }

    chmod((options.root + "/run/control").c_str(), 0770);
#ifdef __ANDROID__
    if (getuid() == 0) chown((options.root + "/run/control").c_str(), 0, 1000);
#endif

    const int server = create_server(options.socket, 1000, &error);
    if (server < 0) {
        std::cerr << "detd: create socket: " << error << '\n';
        close(lock);
        return 1;
    }
    const std::string guest_socket = options.root + "/run/control/detd.sock";
    const int guest_server = create_server(guest_socket, 1000, &error);
    if (guest_server < 0) {
        std::cerr << "detd: guest socket unavailable: " << error << '\n';
    }

    struct sigaction action{};
    action.sa_handler = handle_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, nullptr);
    sigaction(SIGINT, &action, nullptr);
    signal(SIGPIPE, SIG_IGN);

    std::cout << "detd: protocol 1.0 "
              << (options.observe_only ? "observe-only" : "transitions-enabled")
              << " on " << options.socket << '\n';
    while (running.load()) {
        pollfd listeners[2] = {
            {.fd = server, .events = POLLIN, .revents = 0},
            {.fd = guest_server, .events = POLLIN, .revents = 0},
        };
        const nfds_t listener_count = guest_server >= 0 ? 2U : 1U;
        const int ready = poll(listeners, listener_count, -1);
        if (ready < 0) {
            if (errno == EINTR) continue;
            std::cerr << "detd: poll: " << std::strerror(errno) << '\n';
            break;
        }
        for (nfds_t listener = 0; listener < listener_count; ++listener) {
        if ((listeners[listener].revents & POLLIN) == 0) continue;
        const bool is_guest = listener == 1U;
        const int client = accept4(listeners[listener].fd, nullptr, nullptr,
                                   SOCK_CLOEXEC);
        if (client < 0) {
            if (errno == EINTR) continue;
            std::cerr << "detd: accept: " << std::strerror(errno) << '\n';
            continue;
        }
        ucred peer{};
        socklen_t peer_size = sizeof(peer);
        if (getsockopt(client, SOL_SOCKET, SO_PEERCRED, &peer, &peer_size) != 0) {
            close(client);
            continue;
        }
        if (!endpoint_peer_allowed(is_guest ? Endpoint::Guest : Endpoint::Admin,
                                   peer.uid)) {
            close(client);
            continue;
        }
        const ReceiveResult received = receive_packet(client);
        Packet response;
        if (!received.ok) {
            response.header.flags = kFlagResponse;
            response.header.status = static_cast<std::int32_t>(received.status);
            response.payload = "{\"error\":\"" + json_escape(received.error) + "\"}";
        } else {
            response = response_for(received.packet, options, &controller,
                                    peer.uid, is_guest);
        }
        std::string send_error;
        if (!send_packet(client, response, &send_error)) {
            std::cerr << "detd: response: " << send_error << '\n';
        }
        close(client);
        }
    }

    close(server);
    if (guest_server >= 0) close(guest_server);
    unlink(options.socket.c_str());
    unlink(guest_socket.c_str());
    close(lock);
    return 0;
}
