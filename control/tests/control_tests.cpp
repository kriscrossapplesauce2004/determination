#include "determination/control/adapter.hpp"
#include "determination/control/observability.hpp"
#include "determination/control/policy.hpp"
#include "determination/control/protocol.hpp"
#include "determination/control/state.hpp"
#include "determination/control/system.hpp"
#include "determination/control/transition.hpp"

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <unistd.h>

using namespace determination::control;

namespace {

[[noreturn]] void fail_check(const char *expression, const char *file, int line)
{
    std::cerr << file << ':' << line << ": check failed: " << expression << '\n';
    std::exit(1);
}

#define CHECK(expression) \
    do { if (!(expression)) fail_check(#expression, __FILE__, __LINE__); } while (false)

std::string temporary_directory()
{
    char pattern[] = "/tmp/det-control-test-XXXXXX";
    char *directory = mkdtemp(pattern);
    CHECK(directory != nullptr);
    return directory;
}

void write_executable(const std::string &path, const std::string &contents)
{
    const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                        0755);
    CHECK(fd >= 0);
    std::size_t offset = 0;
    while (offset < contents.size()) {
        const ssize_t written = write(fd, contents.data() + offset,
                                      contents.size() - offset);
        CHECK(written > 0);
        offset += static_cast<std::size_t>(written);
    }
    CHECK(close(fd) == 0);
    CHECK(chmod(path.c_str(), 0755) == 0);
}

void prepare_fake_adapters(const std::string &root, bool fail_enter)
{
    std::string error;
    CHECK(ensure_directory(root + "/bin", 0755, &error));
    CHECK(ensure_directory(root + "/run", 0755, &error));
    CHECK(ensure_directory(root + "/state", 0755, &error));
    write_executable(root + "/bin/guest-start", "#!/bin/sh\nexit 0\n");
    write_executable(
        root + "/bin/desktop-on",
        "#!/bin/sh\nmkdir -p '" + root + "/run'\ntouch '" + root +
            "/run/desktop-mode'\n" + (fail_enter ? "exit 7\n" : "exit 0\n"));
    write_executable(root + "/bin/desktop-off",
                     "#!/bin/sh\nrm -f '" + root + "/run/desktop-mode'\nexit 0\n");
}

void state_round_trip()
{
    const std::string root = temporary_directory();
    const std::string path = root + "/nested/control.state";
    StateStore store(path);
    StateRecord original;
    original.generation = 42;
    original.boot_id = "test-boot";
    original.desired = Mode::Desktop;
    original.observed = Mode::Entering;
    original.transition_id = 99;
    original.step = "adapter desktop-on";
    original.completed_steps = {"guest-start", "input-grab"};
    original.started_monotonic_ms = 1000;
    original.deadline_monotonic_ms = 9000;
    original.adapter_status = 7;
    original.last_error = "line one\nline two = awkward % value";
    original.adapter_output = "hello\nworld";
    std::string error;
    CHECK(store.save(original, &error));

    StateRecord loaded;
    CHECK(store.load(&loaded, &error));
    CHECK(loaded.generation == original.generation);
    CHECK(loaded.boot_id == original.boot_id);
    CHECK(loaded.desired == Mode::Desktop);
    CHECK(loaded.observed == Mode::Entering);
    CHECK(loaded.step == original.step);
    CHECK(loaded.completed_steps == original.completed_steps);
    CHECK(loaded.last_error == original.last_error);
    CHECK(loaded.adapter_output == original.adapter_output);
    CHECK(state_json(loaded).find("\"generation\":42") != std::string::npos);
    CHECK(key_value("A=one\nB='two words'\nA=last\n", "A") == "last");
    CHECK(key_value("A=one\nB='two words'\n", "B") == "two words");
    CHECK(key_value("A=one\n", "missing").empty());
}

void transition_success_and_rollback()
{
    const std::string root = temporary_directory();
    prepare_fake_adapters(root, false);
    TransitionController controller(root, true);
    std::string error;
    CHECK(controller.initialise(&error));

    TransitionRequestResult request = controller.request(Mode::Desktop, 101, 5000);
    CHECK(request.status == Status::Accepted);
    CHECK(controller.wait_for_idle(3000));
    StateRecord state = controller.snapshot();
    CHECK(state.observed == Mode::Desktop);
    CHECK(state.step == "idle");
    CHECK(state.completed_steps.size() == 2);
    CHECK(state.completed_steps[0] == "guest-start");
    CHECK(state.completed_steps[1] == "desktop-on");

    request = controller.request(Mode::Phone, 102, 5000);
    CHECK(request.status == Status::Accepted);
    CHECK(controller.wait_for_idle(3000));
    state = controller.snapshot();
    CHECK(state.observed == Mode::Phone);
    CHECK(state.completed_steps.size() == 1);
    CHECK(state.completed_steps[0] == "desktop-off");

    const std::string failing_root = temporary_directory();
    prepare_fake_adapters(failing_root, true);
    TransitionController failing(failing_root, true);
    CHECK(failing.initialise(&error));
    request = failing.request(Mode::Desktop, 103, 5000);
    CHECK(request.status == Status::Accepted);
    CHECK(failing.wait_for_idle(3000));
    state = failing.snapshot();
    CHECK(state.observed == Mode::Phone);
    CHECK(state.step == "rollback-complete");
    CHECK(state.last_error.find("desktop-on") != std::string::npos);
    CHECK(!path_exists(failing_root + "/run/desktop-mode"));
}

void transition_conflicts_and_reconciliation()
{
    const std::string root = temporary_directory();
    prepare_fake_adapters(root, false);
    write_executable(
        root + "/bin/desktop-on",
        "#!/bin/sh\nsleep 0.3\ntouch '" + root + "/run/desktop-mode'\nexit 0\n");
    TransitionController controller(root, true);
    std::string error;
    CHECK(controller.initialise(&error));
    TransitionRequestResult request = controller.request(Mode::Desktop, 201, 5000);
    CHECK(request.status == Status::Accepted);
    request = controller.request(Mode::Desktop, 202, 5000);
    CHECK(request.status == Status::Accepted);
    CHECK(request.message.find("coalesced") != std::string::npos);
    request = controller.request(Mode::Phone, 203, 5000);
    CHECK(request.status == Status::Busy);
    CHECK(controller.wait_for_idle(3000));
    CHECK(controller.snapshot().observed == Mode::Desktop);

    const std::string recovery_root = temporary_directory();
    prepare_fake_adapters(recovery_root, false);
    CHECK(path_exists(recovery_root + "/run"));
    write_executable(recovery_root + "/run/desktop-mode", "stale marker\n");
    StateRecord interrupted;
    interrupted.boot_id = boot_id();
    interrupted.generation = 7;
    interrupted.desired = Mode::Desktop;
    interrupted.observed = Mode::Entering;
    interrupted.step = "desktop-on";
    StateStore store(recovery_root + "/state/control.state");
    CHECK(store.save(interrupted, &error));

    TransitionController recovering(recovery_root, true);
    CHECK(recovering.initialise(&error));
    StateRecord state = recovering.snapshot();
    CHECK(state.observed == Mode::Recovery);
    CHECK(state.desired == Mode::Phone);
    CHECK(state.step == "daemon-restart-reconcile");
    request = recovering.request(Mode::Phone, 204, 5000);
    CHECK(request.status == Status::Accepted);
    CHECK(recovering.wait_for_idle(3000));
    state = recovering.snapshot();
    CHECK(state.observed == Mode::Phone);
    CHECK(!path_exists(recovery_root + "/run/desktop-mode"));
}

void packet_round_trip()
{
    int pair[2];
    CHECK(socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, pair) == 0);
    Packet sent;
    sent.header.operation = static_cast<std::uint32_t>(Operation::Doctor);
    sent.header.request_id = 1234;
    sent.payload = "{\"request\":true}";
    std::string error;
    CHECK(send_packet(pair[0], sent, &error));
    const ReceiveResult received = receive_packet(pair[1]);
    CHECK(received.ok);
    CHECK(received.packet.header.operation == sent.header.operation);
    CHECK(received.packet.header.request_id == sent.header.request_id);
    CHECK(received.packet.payload == sent.payload);
    close(pair[0]);
    close(pair[1]);
}

void invalid_packet_is_rejected()
{
    int pair[2];
    CHECK(socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, pair) == 0);
    const char junk[] = "not a control packet";
    iovec vector{.iov_base = const_cast<char *>(junk), .iov_len = sizeof(junk)};
    msghdr message{};
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    const ssize_t sent = ::sendmsg(pair[0], &message, MSG_NOSIGNAL);
    CHECK(sent == static_cast<ssize_t>(sizeof(junk)));
    const ReceiveResult received = receive_packet(pair[1]);
    CHECK(!received.ok);
    CHECK(received.status == Status::InvalidRequest);
    close(pair[0]);
    close(pair[1]);
}

void adapter_runner()
{
    const AdapterResult success = run_adapter(
        "/bin/sh", {"-c", "printf success; exit 0"}, std::chrono::seconds(2));
    CHECK(success.started);
    CHECK(!success.timed_out);
    CHECK(success.exit_status == 0);
    CHECK(success.output == "success");

    const AdapterResult failure = run_adapter(
        "/bin/sh", {"-c", "printf failed; exit 7"}, std::chrono::seconds(2));
    CHECK(failure.exit_status == 7);
    CHECK(failure.output == "failed");

    const AdapterResult timeout = run_adapter(
        "/bin/sh", {"-c", "sleep 5"}, std::chrono::milliseconds(50));
    CHECK(timeout.timed_out);
}

void utility_contracts()
{
    CHECK(mode_name(parse_mode("phone")) == "phone");
    CHECK(parse_mode("nonsense") == Mode::Unknown);
    CHECK(json_escape("a\n\"b") == "a\\n\\\"b");
    CHECK(fnv1a64("hello") == 0xa430d84680aabd0bULL);
    CHECK(sizeof(PacketHeader) == 48);
    const char own_state = process_state(trim(read_file("/proc/self/comm", 256)));
    CHECK(own_state == 'R' || own_state == 'S' || own_state == 'D');
    CHECK(endpoint_peer_allowed(Endpoint::Admin, 0));
    CHECK(endpoint_peer_allowed(Endpoint::Admin, 1000));
    CHECK(!endpoint_peer_allowed(Endpoint::Admin, 2000));
    CHECK(mode_request_allowed(Endpoint::Admin, 0, Mode::Desktop));
    CHECK(!mode_request_allowed(Endpoint::Admin, 1000, Mode::Phone));
    CHECK(mode_request_allowed(Endpoint::Guest, 1000, Mode::Phone));
    CHECK(!mode_request_allowed(Endpoint::Guest, 1000, Mode::Desktop));
    CHECK(!mode_request_allowed(Endpoint::Guest, 0, Mode::Desktop));
    CHECK(recovery_request_allowed(Endpoint::Guest, 1000));
    CHECK(guest_report_allowed(Endpoint::Guest, 1000));
    CHECK(!guest_report_allowed(Endpoint::Admin, 0));
    const std::string atomic_root = temporary_directory();
    const std::string atomic_path = atomic_root + "/nested/value";
    std::string write_error;
    CHECK(atomic_write_file(atomic_path, "first\n", 0640, &write_error));
    CHECK(trim(read_file(atomic_path)) == "first");
    CHECK(atomic_write_file(atomic_path, "second\n", 0640, &write_error));
    CHECK(trim(read_file(atomic_path)) == "second");
}

void observability_contracts()
{
    const std::string root = temporary_directory();
    std::string error;
    CHECK(ensure_directory(root + "/bin", 0755, &error));
    CHECK(ensure_directory(root + "/run", 0755, &error));
    write_executable(root + "/bin/desktop-off", "#!/bin/sh\nexit 0\n");
    write_executable(root + "/bin/det-audio-probe", "#!/bin/sh\nexit 0\n");

    StateRecord state;
    state.generation = 17;
    state.boot_id = "fixture";
    state.desired = Mode::Phone;
    state.observed = Mode::Phone;
    state.step = "idle";
    const ObservabilityOptions options{root, true};

    const std::string status = status_payload(options, state);
    CHECK(status.find("\"generation\":17") != std::string::npos);
    CHECK(status.find("\"direct_audio\":{\"phase\":\"none\"") !=
          std::string::npos);
    CHECK(status.find("\"probe\":true") != std::string::npos);
    CHECK(doctor_payload(options, state).find("\"healthy\":true") !=
          std::string::npos);
    CHECK(metrics_payload(options, state).find("\"audio_phase\":\"none\"") !=
          std::string::npos);
    CHECK(capabilities_payload(options, false).find(
              "\"android_pcm_bridge\":false") != std::string::npos);

    CHECK(atomic_write_file(
        root + "/run/audio-owner.state",
        "schema=1\nphase=restore-failed\nboot_id=fixture\n"
        "profile=guacamoleb\nprofile_hash=1\nerror=fixture\n",
        0640, &error));
    CHECK(doctor_payload(options, state).find("\"healthy\":false") !=
          std::string::npos);
    CHECK(metrics_payload(options, state).find(
              "\"audio_phase\":\"restore-failed\"") != std::string::npos);

    CHECK(atomic_write_file(
        root + "/run/audio-owner.state",
        "schema=1\nphase=claimed\nboot_id=fixture\n"
        "profile=guacamoleb\nprofile_hash=1\nerror=\n",
        0640, &error));
    CHECK(doctor_payload(options, state).find(
              "\"direct_audio_mode_consistent\":false") != std::string::npos);
}

} // namespace

int main()
{
    state_round_trip();
    packet_round_trip();
    invalid_packet_is_rejected();
    adapter_runner();
    transition_success_and_rollback();
    transition_conflicts_and_reconciliation();
    utility_contracts();
    observability_contracts();
    std::cout << "all control-plane tests passed\n";
    return 0;
}
