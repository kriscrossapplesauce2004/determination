#include "determination/control/adapter.hpp"
#include "determination/control/protocol.hpp"
#include "determination/control/state.hpp"
#include "determination/control/system.hpp"

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
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
    CHECK(loaded.last_error == original.last_error);
    CHECK(loaded.adapter_output == original.adapter_output);
    CHECK(state_json(loaded).find("\"generation\":42") != std::string::npos);
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
}

} // namespace

int main()
{
    state_round_trip();
    packet_round_trip();
    invalid_packet_is_rejected();
    adapter_runner();
    utility_contracts();
    std::cout << "all control-plane tests passed\n";
    return 0;
}
