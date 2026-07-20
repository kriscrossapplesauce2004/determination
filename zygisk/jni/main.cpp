// Determination Zygisk module — SF-death suppression hook.
// PLT-hooks __system_property_set in system_server: when desktop-mode is
// active, swallows ctl.start/ctl.restart for surfaceflinger so the stopped
// SF stays stopped (replacing the shell suppressor loop in desktop-on).

#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <array>
#include <string>
#include <vector>
#include <thread>
#include <unistd.h>

#include "zygisk.hpp"
#include "determination/control/protocol.hpp"

static constexpr const char *FLAG = "/data/determination/run/desktop-mode";
static constexpr const char *APP_PROCESS = "com.determination.companion";
static constexpr const char *BRIDGE_NAME = "determination.companion.bridge";
static constexpr const char *DETD_SOCKET = "/data/determination/run/detd.sock";
static int (*orig_system_property_set)(const char *, const char *) = nullptr;

static bool write_all(int fd, const void *data, size_t size) {
    const auto *p = static_cast<const uint8_t *>(data);
    while (size > 0) {
        ssize_t n = write(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n;
        size -= static_cast<size_t>(n);
    }
    return true;
}

static bool read_all(int fd, void *data, size_t size) {
    auto *p = static_cast<uint8_t *>(data);
    while (size > 0) {
        ssize_t n = read(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n;
        size -= static_cast<size_t>(n);
    }
    return true;
}

static void write_protocol_error(
    int client, const determination::control::PacketHeader &request,
    determination::control::Status status, const char *message) {
    using namespace determination::control;
    PacketHeader response{};
    response.flags = kFlagResponse;
    response.operation = request.operation;
    response.status = static_cast<int32_t>(status);
    response.request_id = request.request_id;
    const std::string payload = std::string("{\"error\":\"") + message + "\"}";
    response.payload_size = static_cast<uint32_t>(payload.size());
    write_all(client, &response, sizeof(response));
    write_all(client, payload.data(), payload.size());
}

static void forward_protocol_request(
    int client, const determination::control::PacketHeader &request) {
    using namespace determination::control;
    if (request.major != kProtocolMajor || request.header_size != sizeof(PacketHeader) ||
        request.payload_size > kMaximumPayload || (request.flags & kFlagResponse)) {
        write_protocol_error(client, request, Status::InvalidRequest,
                             "invalid control packet");
        return;
    }
    std::vector<uint8_t> payload(request.payload_size);
    if (!payload.empty() && !read_all(client, payload.data(), payload.size())) {
        write_protocol_error(client, request, Status::InvalidRequest,
                             "truncated control payload");
        return;
    }

    int daemon = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (daemon < 0) {
        write_protocol_error(client, request, Status::Unavailable,
                             "detd socket failed");
        return;
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, DETD_SOCKET, strlen(DETD_SOCKET) + 1);
    if (connect(daemon, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
        close(daemon);
        write_protocol_error(client, request, Status::Unavailable,
                             "detd unavailable");
        return;
    }

    iovec request_vectors[2] = {
        {.iov_base = const_cast<PacketHeader *>(&request), .iov_len = sizeof(request)},
        {.iov_base = payload.data(), .iov_len = payload.size()},
    };
    msghdr outgoing{};
    outgoing.msg_iov = request_vectors;
    outgoing.msg_iovlen = payload.empty() ? 1 : 2;
    if (sendmsg(daemon, &outgoing, MSG_NOSIGNAL) !=
        static_cast<ssize_t>(sizeof(request) + payload.size())) {
        close(daemon);
        write_protocol_error(client, request, Status::Unavailable,
                             "detd request failed");
        return;
    }

    std::array<uint8_t, sizeof(PacketHeader) + kMaximumPayload> response{};
    iovec response_vector{.iov_base = response.data(), .iov_len = response.size()};
    msghdr incoming{};
    incoming.msg_iov = &response_vector;
    incoming.msg_iovlen = 1;
    const ssize_t received = recvmsg(daemon, &incoming, MSG_CMSG_CLOEXEC);
    close(daemon);
    if (received < static_cast<ssize_t>(sizeof(PacketHeader)) ||
        (incoming.msg_flags & (MSG_TRUNC | MSG_CTRUNC))) {
        write_protocol_error(client, request, Status::Unavailable,
                             "detd response failed");
        return;
    }
    PacketHeader response_header{};
    memcpy(&response_header, response.data(), sizeof(response_header));
    if (response_header.magic != kProtocolMagic ||
        response_header.major != kProtocolMajor ||
        response_header.header_size != sizeof(PacketHeader) ||
        response_header.payload_size > kMaximumPayload ||
        static_cast<size_t>(received) != sizeof(PacketHeader) + response_header.payload_size) {
        write_protocol_error(client, request, Status::ProtocolMismatch,
                             "invalid detd response");
        return;
    }
    write_all(client, response.data(), static_cast<size_t>(received));
}

static void launch_fixed_action(const char *command, int client) {
    const char *script = nullptr;
    if (strcmp(command, "enter") == 0) {
        script = "/data/determination/bin/guest-start >/dev/null 2>&1; "
                 "setsid sh -c 'nohup /data/determination/bin/desktop-on "
                 ">/dev/null 2>&1' >/dev/null 2>&1 &";
    } else if (strcmp(command, "exit") == 0) {
        script = "setsid sh -c 'nohup /data/determination/bin/desktop-off "
                 ">/dev/null 2>&1' >/dev/null 2>&1 &";
    } else if (strcmp(command, "ping") == 0) {
        write_all(client, "ok bridge\n", 10);
        return;
    } else {
        write_all(client, "error unknown-command\n", 22);
        return;
    }

    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        execl("/system/bin/sh", "sh", "-c", script, nullptr);
        _exit(127);
    }
    if (pid < 0) write_all(client, "error fork\n", 11);
    else write_all(client, "ok\n", 3);
}

// Runs in Magisk's root companion process. Only enumerated commands reach a
// shell; no arbitrary command strings cross this privilege boundary.
static void root_companion_handler(int client) {
    uint32_t prefix = 0;
    if (!read_all(client, &prefix, sizeof(prefix))) return;
    if (prefix == determination::control::kProtocolMagic) {
        determination::control::PacketHeader request{};
        request.magic = prefix;
        if (!read_all(client, reinterpret_cast<uint8_t *>(&request) + sizeof(prefix),
                      sizeof(request) - sizeof(prefix))) {
            return;
        }
        forward_protocol_request(client, request);
        return;
    }

    char command[32] = {};
    memcpy(command, &prefix, sizeof(prefix));
    ssize_t n;
    do n = read(client, command + sizeof(prefix),
                sizeof(command) - sizeof(prefix) - 1);
    while (n < 0 && errno == EINTR);
    if (n < 0) return;
    command[sizeof(prefix) + static_cast<size_t>(n)] = '\0';
    char *newline = strpbrk(command, "\r\n");
    if (newline) *newline = '\0';
    launch_fixed_action(command, client);
}

static int hooked_system_property_set(const char *key, const char *value) {
    if (key && value &&
        (strcmp(key, "ctl.start") == 0 || strcmp(key, "ctl.restart") == 0) &&
        strcmp(value, "surfaceflinger") == 0) {
        struct stat st;
        if (stat(FLAG, &st) == 0) {
            return 0;
        }
    }
    return orig_system_property_set(key, value);
}

// Scan /proc/self/maps for loaded ELF, return true and set dev/ino.
static bool find_lib(const char *name, dev_t *dev, ino_t *ino) {
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) return false;
    char line[512];
    size_t nlen = strlen(name);
    while (fgets(line, sizeof(line), f)) {
        // Match lines containing the library name as a path suffix
        char *p = strstr(line, name);
        if (!p) continue;
        // Ensure it's a full basename match (preceded by '/')
        if (p > line && *(p - 1) != '/') continue;
        // Ensure the match ends at newline or whitespace (not a prefix of another lib)
        char end = *(p + nlen);
        if (end != '\n' && end != '\0' && end != ' ') continue;

        // Parse dev and inode from the maps line
        // Format: addr perms offset dev inode pathname
        unsigned int dev_maj, dev_min;
        unsigned long inode_val;
        // Skip addr, perms, offset — find dev field (4th column)
        char *col = line;
        for (int i = 0; i < 3; i++) {
            col = strchr(col, ' ');
            if (!col) break;
            while (*col == ' ') col++;
        }
        if (!col) continue;
        if (sscanf(col, "%x:%x %lu", &dev_maj, &dev_min, &inode_val) != 3) continue;
        if (inode_val == 0) continue;
        *dev = makedev(dev_maj, dev_min);
        *ino = (ino_t)inode_val;
        fclose(f);
        return true;
    }
    fclose(f);
    return false;
}

class DeterminationModule : public zygisk::ModuleBase {
    zygisk::Api *api_ = nullptr;
    JNIEnv *env_ = nullptr;
    bool is_companion_app_ = false;

    void serve_app_bridge() {
        int server = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (server < 0) return;

        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        const size_t name_len = strlen(BRIDGE_NAME);
        address.sun_path[0] = '\0';
        memcpy(address.sun_path + 1, BRIDGE_NAME, name_len);
        socklen_t address_len = static_cast<socklen_t>(
            offsetof(sockaddr_un, sun_path) + 1 + name_len);
        if (bind(server, reinterpret_cast<sockaddr *>(&address), address_len) != 0 ||
            listen(server, 4) != 0) {
            close(server);
            return;
        }

        const uid_t own_uid = getuid();
        while (true) {
            int app = accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
            if (app < 0) {
                if (errno == EINTR) continue;
                break;
            }
            ucred peer{};
            socklen_t peer_len = sizeof(peer);
            if (getsockopt(app, SOL_SOCKET, SO_PEERCRED, &peer, &peer_len) != 0 ||
                peer.uid != own_uid) {
                close(app);
                continue;
            }

            int root = api_->connectCompanion();
            if (root >= 0) {
                std::array<uint8_t, 4096> request{};
                size_t total = 0;
                ssize_t n;
                while ((n = read(app, request.data(), request.size())) > 0) {
                    total += static_cast<size_t>(n);
                    if (total > sizeof(determination::control::PacketHeader) +
                                    determination::control::kMaximumPayload ||
                        !write_all(root, request.data(), static_cast<size_t>(n))) {
                        break;
                    }
                }
                shutdown(root, SHUT_WR);
                std::array<uint8_t, 4096> response{};
                while ((n = read(root, response.data(), response.size())) > 0)
                    if (!write_all(app, response.data(), static_cast<size_t>(n))) break;
                close(root);
            } else {
                write_all(app, "error no-root-companion\n", 24);
            }
            close(app);
        }
        close(server);
    }

public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        api_ = api;
        env_ = env;
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        const char *name = env_->GetStringUTFChars(args->nice_name, nullptr);
        is_companion_app_ = name && strcmp(name, APP_PROCESS) == 0;
        if (name) env_->ReleaseStringUTFChars(args->nice_name, name);
        if (!is_companion_app_) api_->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (is_companion_app_)
            std::thread([this] { serve_app_bridge(); }).detach();
    }

    void postServerSpecialize(const zygisk::ServerSpecializeArgs *) override {
        // We're in system_server. Hook __system_property_set in every
        // library that might issue ctl.start/restart surfaceflinger.
        static const char *targets[] = {
            "libgui.so",
            "libcutils.so",
            "libandroid_runtime.so",
            "libsurfaceflinger_client.so",
            "libutils.so",
        };

        dev_t dev;
        ino_t ino;
        int registered = 0;
        for (auto lib : targets) {
            if (find_lib(lib, &dev, &ino)) {
                api_->pltHookRegister(dev, ino, "__system_property_set",
                    reinterpret_cast<void *>(hooked_system_property_set),
                    reinterpret_cast<void **>(&orig_system_property_set));
                registered++;
            }
        }

        if (registered > 0) {
            api_->pltHookCommit();
        }
    }
};

REGISTER_ZYGISK_MODULE(DeterminationModule)
REGISTER_ZYGISK_COMPANION(root_companion_handler)
