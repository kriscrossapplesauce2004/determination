#include "determination/control/observability.hpp"

#include "determination/control/system.hpp"

#include <cstdlib>
#include <iomanip>
#include <sstream>
#include <sys/statvfs.h>

namespace determination::control {
namespace {

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

std::string process_state_json(const std::map<std::string, char> &states,
                               const std::string &name)
{
    const auto found = states.find(name);
    const char state = found == states.end() ? '?' : found->second;
    return state == '-' ? "null" : std::string("\"") + state + '"';
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

std::string data_free(const std::string &root)
{
    struct statvfs status {};
    if (statvfs(root.c_str(), &status) != 0) return {};
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

std::string guest_state(const std::string &root,
                        const std::map<std::string, char> &states)
{
    const std::string command = root + "/run/lxc/guest/command";
    if (path_exists(command)) return "running";
    const auto lxc = states.find("lxc-start");
    if (lxc != states.end() && lxc->second != '-') return "running";
    return "stopped";
}

std::string audio_phase(const ObservabilityOptions &options)
{
    const std::string phase = key_value(
        read_file(options.root + "/run/audio-owner.state", 64U * 1024U), "phase");
    return phase.empty() ? "none" : phase;
}

bool audio_phase_stable(const std::string &phase)
{
    return phase == "none" || phase == "restored" || phase == "rolled-back" ||
           phase == "claimed";
}

bool presenter_socket_ready()
{
    return path_exists(
        "/data/user_de/0/com.determination.companion/files/presenter.sock");
}

} // namespace

std::string status_payload(const ObservabilityOptions &options,
                           const StateRecord &state)
{
    const std::string sf = android_property("init.svc.surfaceflinger");
    const std::string profile = read_file(options.root + "/etc/device.conf");
    std::string gauge = key_value(profile, "DET_BATTERY_GAUGE");
    if (gauge.empty()) gauge = "battery";
    const std::string battery_root = "/sys/class/power_supply/" + gauge;
    const std::string voltage = trim(read_file(battery_root + "/voltage_now", 64));
    const std::uint64_t millivolts =
        std::strtoull(voltage.c_str(), nullptr, 10) / 1000U;
    const Mode live = observed_mode(options.root);
    const std::string guest_report = trim(
        read_file(options.root + "/run/guest-health.json", 8192));
    const bool guest_report_is_object = guest_report.size() >= 2U &&
        guest_report.front() == '{' && guest_report.back() == '}';
    const std::string direct_audio_phase = audio_phase(options);
    const std::string audio_profile = key_value(
        read_file(options.root + "/etc/audio-owner.conf", 64U * 1024U), "profile");
    const auto processes = process_states(
        {"system_server", "phoc", "phosh", "lxc-start"});
    std::ostringstream output;
    output << "{\"protocol\":\"1.0\""
           << ",\"observe_only\":" << (options.observe_only ? "true" : "false")
           << ",\"state\":" << state_json(state)
           << ",\"live_observed\":\"" << mode_name(live) << '"'
           << ",\"surfaceflinger\":\"" << json_escape(sf.empty() ? "unknown" : sf) << '"'
           << ",\"processes\":{\"system_server\":"
           << process_state_json(processes, "system_server")
           << ",\"phoc\":" << process_state_json(processes, "phoc")
           << ",\"phosh\":" << process_state_json(processes, "phosh") << '}'
           << ",\"memory\":{\"available\":\"" << json_escape(memory_value("MemAvailable"))
           << "\",\"swap_free\":\"" << json_escape(memory_value("SwapFree")) << "\"}"
           << ",\"guest_report\":"
           << (guest_report_is_object ? guest_report : "null")
           << ",\"direct_audio\":{\"phase\":\""
           << json_escape(direct_audio_phase) << "\",\"profile\":\""
           << json_escape(audio_profile) << "\",\"probe\":"
           << (path_exists(options.root + "/bin/det-audio-probe") ? "true" : "false")
           << ",\"owner\":"
           << (path_exists(options.root + "/bin/det-audio-owner") ? "true" : "false")
           << "}"
           << ",\"presenter\":{\"socket_ready\":"
           << (presenter_socket_ready() ? "true" : "false") << "}"
           << ",\"profile_digest\":\"" << std::hex << fnv1a64(profile) << std::dec << '"'
           << ",\"compat\":{\"uid\":\"0\",\"kernel\":\""
           << json_escape(trim(read_file("/proc/sys/kernel/osrelease", 256)))
           << "\",\"sf\":\"" << json_escape(sf.empty() ? "unknown" : sf)
           << "\",\"mode\":\"" << mode_name(live)
           << "\",\"guest\":\"" << guest_state(options.root, processes)
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
           << "\",\"datafree\":\"" << data_free(options.root) << "\"}}";
    return output.str();
}

std::string doctor_payload(const ObservabilityOptions &options,
                           const StateRecord &state)
{
    const bool marker = path_exists(options.root + "/run/desktop-mode");
    const bool mismatch = marker != (state.observed == Mode::Desktop);
    const bool recovery = state.observed == Mode::Recovery;
    const bool stable = state.observed == Mode::Phone || state.observed == Mode::Desktop;
    const bool guest_tools = path_exists(options.root + "/lxc/bin/lxc-info");
    const bool emergency = path_exists(options.root + "/bin/desktop-off");
    const std::string direct_audio_phase = audio_phase(options);
    const bool audio_stable = audio_phase_stable(direct_audio_phase);
    const bool audio_mode_consistent = direct_audio_phase != "claimed" || marker;
    std::ostringstream output;
    output << "{\"healthy\":"
           << (!mismatch && !recovery && stable && emergency && audio_stable &&
                       audio_mode_consistent
                   ? "true" : "false")
           << ",\"state\":" << state_json(state)
           << ",\"checks\":{\"state_marker_consistent\":" << (!mismatch ? "true" : "false")
           << ",\"emergency_phone_restore\":" << (emergency ? "true" : "false")
           << ",\"guest_tools\":" << (guest_tools ? "true" : "false")
           << ",\"binderfs\":" << (path_exists("/dev/binderfs") ? "true" : "false")
           << ",\"pid_namespace\":" << (path_exists("/proc/self/ns/pid") ? "true" : "false")
           << ",\"direct_audio_phase_stable\":" << (audio_stable ? "true" : "false")
           << ",\"direct_audio_mode_consistent\":"
           << (audio_mode_consistent ? "true" : "false")
           << ",\"direct_audio_probe\":"
           << (path_exists(options.root + "/bin/det-audio-probe") ? "true" : "false")
           << ",\"presenter_socket_ready\":"
           << (presenter_socket_ready() ? "true" : "false")
           << "},\"memory_pressure\":\""
           << json_escape(trim(read_file("/proc/pressure/memory", 4096))) << "\"}";
    return output.str();
}

std::string metrics_payload(const ObservabilityOptions &options,
                            const StateRecord &state)
{
    const auto processes = process_states({"system_server", "phoc", "phosh"});
    std::ostringstream output;
    output << "{\"schema\":1,\"monotonic_ms\":" << monotonic_milliseconds()
           << ",\"generation\":" << state.generation
           << ",\"mode\":\"" << mode_name(state.observed)
           << "\",\"step\":\"" << json_escape(state.step) << '"'
           << ",\"memory\":{\"available\":\"" << json_escape(memory_value("MemAvailable"))
           << "\",\"swap_free\":\"" << json_escape(memory_value("SwapFree"))
           << "\"},\"pressure\":{\"cpu\":\""
           << json_escape(trim(read_file("/proc/pressure/cpu", 4096)))
           << "\",\"memory\":\""
           << json_escape(trim(read_file("/proc/pressure/memory", 4096)))
           << "\",\"io\":\"" << json_escape(trim(read_file("/proc/pressure/io", 4096)))
           << "\"},\"processes\":{\"system_server\":"
           << process_state_json(processes, "system_server")
           << ",\"phoc\":" << process_state_json(processes, "phoc")
           << ",\"phosh\":" << process_state_json(processes, "phosh")
           << "},\"audio_phase\":\"" << json_escape(audio_phase(options))
           << "\",\"presenter_socket_ready\":"
           << (presenter_socket_ready() ? "true" : "false")
           << ",\"data_free\":\"" << json_escape(data_free(options.root)) << "\"}";
    return output.str();
}

std::string capabilities_payload(const ObservabilityOptions &options,
                                 bool guest_endpoint)
{
    return "{\"operations\":[\"hello\",\"ping\",\"status\",\"doctor\","
           "\"capabilities\",\"metrics\",\"mode-get\",\"mode-set\","
           "\"mode-recover\",\"boot-profile-get\",\"boot-profile-set\","
           "\"boot-profile-apply\",\"guest-report\"],\"guest_endpoint\":" +
           std::string(guest_endpoint ? "true" : "false") +
           ",\"transitions\":" +
           std::string(options.observe_only ? "false" : "true") +
           ",\"structured_state\":true,\"authenticated_peer_credentials\":true,"
           "\"direct_audio\":{\"transport\":\"alsa\","
           "\"android_pcm_bridge\":false,\"automatic\":false,\"probe\":" +
           std::string(path_exists(options.root + "/bin/det-audio-probe")
                           ? "true" : "false") +
           ",\"owner\":" +
           std::string(path_exists(options.root + "/bin/det-audio-owner")
                           ? "true" : "false") +
           "},\"presenter_protocol\":1}";
}

} // namespace determination::control
