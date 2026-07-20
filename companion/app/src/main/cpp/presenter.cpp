#include <jni.h>

#include <android/hardware_buffer.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <android/rect.h>
#include <android/surface_control.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <memory>
#include <mutex>
#include <string>
#include <stdexcept>
#include <thread>
#include <unordered_map>
#include <utility>

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "presenter-protocol.h"
#include "presenter-policy.h"

namespace {

constexpr char kTag[] = "DetPresenter";

#define DET_LOGI(...) __android_log_print(ANDROID_LOG_INFO, kTag, __VA_ARGS__)
#define DET_LOGW(...) __android_log_print(ANDROID_LOG_WARN, kTag, __VA_ARGS__)
#define DET_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, kTag, __VA_ARGS__)

struct SurfaceApi {
    void *library = nullptr;
    ASurfaceControl *(*createFromWindow)(ANativeWindow *, const char *) = nullptr;
    void (*acquireSurface)(ASurfaceControl *) = nullptr;
    void (*releaseSurface)(ASurfaceControl *) = nullptr;
    ASurfaceTransaction *(*createTransaction)() = nullptr;
    void (*deleteTransaction)(ASurfaceTransaction *) = nullptr;
    void (*apply)(ASurfaceTransaction *) = nullptr;
    void (*setVisibility)(ASurfaceTransaction *, ASurfaceControl *,
                          ASurfaceTransactionVisibility) = nullptr;
    void (*setZOrder)(ASurfaceTransaction *, ASurfaceControl *, int32_t) = nullptr;
    void (*setGeometry)(ASurfaceTransaction *, ASurfaceControl *, const ARect &,
                        const ARect &, int32_t) = nullptr;
    void (*setBuffer)(ASurfaceTransaction *, ASurfaceControl *, AHardwareBuffer *,
                      int) = nullptr;
    void (*setDesiredPresentTime)(ASurfaceTransaction *, int64_t) = nullptr;
    void (*setOnComplete)(ASurfaceTransaction *, void *,
                          void (*)(void *, ASurfaceTransactionStats *)) = nullptr;
    void (*setEnableBackPressure)(ASurfaceTransaction *, ASurfaceControl *,
                                  bool) = nullptr;
    int64_t (*getLatchTime)(ASurfaceTransactionStats *) = nullptr;
    int (*getPresentFence)(ASurfaceTransactionStats *) = nullptr;
    int (*getReleaseFence)(ASurfaceTransactionStats *, ASurfaceControl *) = nullptr;
    int32_t (*setFrameRate)(ANativeWindow *, float, int8_t) = nullptr;

    SurfaceApi()
    {
        library = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
        if (!library) {
            throw std::runtime_error("dlopen(libandroid.so) failed");
        }
#define DET_REQUIRED(member, symbol)                                        \
    do {                                                                    \
        member = reinterpret_cast<decltype(member)>(dlsym(library, symbol));\
        if (!member) {                                                      \
            throw std::runtime_error(std::string("missing ") + symbol);    \
        }                                                                   \
    } while (0)
        DET_REQUIRED(createFromWindow, "ASurfaceControl_createFromWindow");
        DET_REQUIRED(acquireSurface, "ASurfaceControl_acquire");
        DET_REQUIRED(releaseSurface, "ASurfaceControl_release");
        DET_REQUIRED(createTransaction, "ASurfaceTransaction_create");
        DET_REQUIRED(deleteTransaction, "ASurfaceTransaction_delete");
        DET_REQUIRED(apply, "ASurfaceTransaction_apply");
        DET_REQUIRED(setVisibility, "ASurfaceTransaction_setVisibility");
        DET_REQUIRED(setZOrder, "ASurfaceTransaction_setZOrder");
        DET_REQUIRED(setGeometry, "ASurfaceTransaction_setGeometry");
        DET_REQUIRED(setBuffer, "ASurfaceTransaction_setBuffer");
        DET_REQUIRED(setDesiredPresentTime,
                     "ASurfaceTransaction_setDesiredPresentTime");
        DET_REQUIRED(setOnComplete, "ASurfaceTransaction_setOnComplete");
        DET_REQUIRED(getLatchTime, "ASurfaceTransactionStats_getLatchTime");
        DET_REQUIRED(getPresentFence,
                     "ASurfaceTransactionStats_getPresentFenceFd");
        DET_REQUIRED(getReleaseFence,
                     "ASurfaceTransactionStats_getPreviousReleaseFenceFd");
#undef DET_REQUIRED
        setEnableBackPressure =
            reinterpret_cast<decltype(setEnableBackPressure)>(
                dlsym(library, "ASurfaceTransaction_setEnableBackPressure"));
        setFrameRate = reinterpret_cast<decltype(setFrameRate)>(
            dlsym(library, "ANativeWindow_setFrameRate"));
    }
};

SurfaceApi &surfaceApi()
{
    static SurfaceApi instance;
    return instance;
}

int64_t monotonicNanos()
{
    timespec now{};
    clock_gettime(CLOCK_MONOTONIC, &now);
    return static_cast<int64_t>(now.tv_sec) * 1000000000LL + now.tv_nsec;
}

struct ReceivedPacket {
    det_presenter_packet packet{};
    int fence = -1;

    ~ReceivedPacket()
    {
        if (fence >= 0) {
            close(fence);
        }
    }
};

bool receivePacket(int fd, ReceivedPacket *received)
{
    iovec iov{
        .iov_base = &received->packet,
        .iov_len = sizeof(received->packet),
    };
    alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int))]{};
    msghdr message{};
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);
    const ssize_t size = recvmsg(fd, &message, MSG_CMSG_CLOEXEC);
    if (size == 0) {
        return false;
    }
    if (size != static_cast<ssize_t>(sizeof(received->packet)) ||
        (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) != 0) {
        DET_LOGW("bad control packet size=%zd flags=0x%x", size, message.msg_flags);
        return false;
    }
    if (received->packet.magic != DET_PRESENTER_MAGIC ||
        received->packet.version != DET_PRESENTER_VERSION ||
        received->packet.size != sizeof(received->packet)) {
        DET_LOGW("bad protocol header magic=0x%x version=%u size=%u",
                 received->packet.magic, received->packet.version,
                 received->packet.size);
        return false;
    }
    for (cmsghdr *header = CMSG_FIRSTHDR(&message); header;
         header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS &&
            header->cmsg_len >= CMSG_LEN(sizeof(int))) {
            std::memcpy(&received->fence, CMSG_DATA(header), sizeof(int));
            break;
        }
    }
    return true;
}

struct Connection : std::enable_shared_from_this<Connection> {
    explicit Connection(int socket) : fd(socket) {}
    ~Connection()
    {
        if (fd >= 0) {
            close(fd);
        }
    }

    bool sendCompletion(det_presenter_packet packet, int presentFence,
                        int releaseFence)
    {
        int fences[2];
        size_t fenceCount = 0;
        if (presentFence >= 0) {
            packet.flags |= DET_PRESENTER_HAS_PRESENT_FENCE;
            fences[fenceCount++] = presentFence;
        }
        if (releaseFence >= 0) {
            packet.flags |= DET_PRESENTER_HAS_RELEASE_FENCE;
            fences[fenceCount++] = releaseFence;
        }

        iovec iov{.iov_base = &packet, .iov_len = sizeof(packet)};
        alignas(cmsghdr) char control[CMSG_SPACE(sizeof(fences))]{};
        msghdr message{};
        message.msg_iov = &iov;
        message.msg_iovlen = 1;
        if (fenceCount) {
            message.msg_control = control;
            message.msg_controllen = CMSG_SPACE(fenceCount * sizeof(int));
            cmsghdr *header = CMSG_FIRSTHDR(&message);
            header->cmsg_level = SOL_SOCKET;
            header->cmsg_type = SCM_RIGHTS;
            header->cmsg_len = CMSG_LEN(fenceCount * sizeof(int));
            std::memcpy(CMSG_DATA(header), fences, fenceCount * sizeof(int));
        }

        std::lock_guard lock(sendMutex);
        return sendmsg(fd, &message, MSG_NOSIGNAL) ==
            static_cast<ssize_t>(sizeof(packet));
    }

    int fd;
    std::mutex sendMutex;
    std::atomic<unsigned int> inflight{0};
};

struct CompletionContext {
    std::shared_ptr<Connection> connection;
    ASurfaceControl *surface = nullptr;
    uint64_t serial = 0;
    uint64_t bufferId = 0;
    uint64_t releasedBufferId = 0;
};

void onComplete(void *opaque, ASurfaceTransactionStats *stats)
{
    std::unique_ptr<CompletionContext> context(
        static_cast<CompletionContext *>(opaque));
    det_presenter_packet packet =
        det_presenter_packet_init(DET_PRESENTER_COMPLETE);
    packet.serial = context->serial;
    packet.buffer_id = context->bufferId;
    packet.released_buffer_id = context->releasedBufferId;
    packet.latch_time_ns = surfaceApi().getLatchTime(stats);
    packet.callback_time_ns = monotonicNanos();

    const int presentFence = surfaceApi().getPresentFence(stats);
    const int releaseFence = context->releasedBufferId
        ? surfaceApi().getReleaseFence(stats, context->surface)
        : -1;
    if (!context->connection->sendCompletion(packet, presentFence,
                                              releaseFence)) {
        DET_LOGW("completion send failed serial=%llu: %s",
                 static_cast<unsigned long long>(context->serial),
                 std::strerror(errno));
    }
    if (presentFence >= 0) {
        close(presentFence);
    }
    if (releaseFence >= 0) {
        close(releaseFence);
    }
    context->connection->inflight.fetch_sub(1);
    surfaceApi().releaseSurface(context->surface);
}

class Presenter {
public:
    Presenter(JNIEnv *env, jobject javaSurface, std::string socketPath,
              int width, int height, float refreshRate)
        : m_socketPath(std::move(socketPath))
        , m_width(width)
        , m_height(height)
    {
        m_window = ANativeWindow_fromSurface(env, javaSurface);
        if (!m_window) {
            throw std::runtime_error("ANativeWindow_fromSurface failed");
        }
        if (refreshRate > 0 && surfaceApi().setFrameRate) {
            surfaceApi().setFrameRate(
                m_window, refreshRate,
                ANATIVEWINDOW_FRAME_RATE_COMPATIBILITY_FIXED_SOURCE);
        }
        m_surface = surfaceApi().createFromWindow(m_window,
                                                  "Determination guest");
        if (!m_surface) {
            ANativeWindow_release(m_window);
            m_window = nullptr;
            throw std::runtime_error("ASurfaceControl_createFromWindow failed");
        }
        m_running.store(true);
        m_thread = std::thread([this] { serve(); });
    }

    ~Presenter()
    {
        m_running.store(false);
        const int server = m_server.exchange(-1);
        if (server >= 0) {
            shutdown(server, SHUT_RDWR);
            close(server);
        }
        const int client = m_client.exchange(-1);
        if (client >= 0) {
            shutdown(client, SHUT_RDWR);
        }
        if (m_thread.joinable()) {
            m_thread.join();
        }
        unlink(m_socketPath.c_str());
        surfaceApi().releaseSurface(m_surface);
        ANativeWindow_release(m_window);
    }

    void resize(int width, int height)
    {
        m_width.store(width);
        m_height.store(height);
    }

private:
    void serve()
    {
        if (m_socketPath.size() >= sizeof(sockaddr_un::sun_path)) {
            DET_LOGE("socket path too long: %s", m_socketPath.c_str());
            return;
        }
        unlink(m_socketPath.c_str());
        const int server = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
        if (server < 0) {
            DET_LOGE("socket failed: %s", std::strerror(errno));
            return;
        }
        m_server.store(server);
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        std::memcpy(address.sun_path, m_socketPath.c_str(),
                    m_socketPath.size() + 1);
        if (bind(server, reinterpret_cast<sockaddr *>(&address),
                 sizeof(address)) != 0 || listen(server, 1) != 0) {
            DET_LOGE("bind/listen %s failed: %s", m_socketPath.c_str(),
                     std::strerror(errno));
            return;
        }
        // The guest sees this inode through a narrow bind mount and runs with
        // uid 1000. The filesystem mode permits that crossing; SO_PEERCRED
        // below is the actual authorization boundary.
        chmod(m_socketPath.c_str(), 0666);
        DET_LOGI("listening on %s", m_socketPath.c_str());

        while (m_running.load()) {
            const int fd = accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
            if (fd < 0) {
                if (m_running.load()) {
                    DET_LOGW("accept failed: %s", std::strerror(errno));
                }
                continue;
            }
            ucred credential{};
            socklen_t credentialSize = sizeof(credential);
            if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credential,
                           &credentialSize) != 0 ||
                (credential.uid != 0 && credential.uid != 1000)) {
                DET_LOGW("rejected presenter peer uid=%u", credential.uid);
                close(fd);
                continue;
            }
            m_client.store(fd);
            handleConnection(std::make_shared<Connection>(fd));
            m_client.store(-1);
        }
    }

    void handleConnection(const std::shared_ptr<Connection> &connection)
    {
        std::unordered_map<uint64_t, AHardwareBuffer *> buffers;
        uint64_t currentBuffer = 0;
        uint64_t registeredPixels = 0;
        uint64_t lastSerial = 0;
        DET_LOGI("guest presenter connected");

        while (m_running.load()) {
            ReceivedPacket received;
            if (!receivePacket(connection->fd, &received)) {
                break;
            }
            const auto &packet = received.packet;
            if (packet.op == DET_PRESENTER_REGISTER) {
                if (received.fence >= 0 || packet.buffer_id == 0 ||
                    !det_presenter_dimensions_valid(packet.width, packet.height) ||
                    buffers.size() >= DET_PRESENTER_MAX_BUFFERS ||
                    buffers.contains(packet.buffer_id)) {
                    DET_LOGW("rejected buffer registration id=%llu %ux%u count=%zu",
                             static_cast<unsigned long long>(packet.buffer_id),
                             packet.width, packet.height, buffers.size());
                    break;
                }
                const uint64_t pixels = static_cast<uint64_t>(packet.width) *
                                        static_cast<uint64_t>(packet.height);
                if (pixels > DET_PRESENTER_MAX_REGISTERED_PIXELS - registeredPixels) {
                    DET_LOGW("registered buffer pixel quota exceeded");
                    break;
                }
                AHardwareBuffer *buffer = nullptr;
                const int status = AHardwareBuffer_recvHandleFromUnixSocket(
                    connection->fd, &buffer);
                if (status != 0 || !buffer) {
                    DET_LOGW("AHardwareBuffer receive failed id=%llu status=%d",
                             static_cast<unsigned long long>(packet.buffer_id),
                             status);
                    break;
                }
                AHardwareBuffer_Desc description{};
                AHardwareBuffer_describe(buffer, &description);
                if (description.width != packet.width ||
                    description.height != packet.height ||
                    description.format != packet.format ||
                    description.stride != packet.stride ||
                    description.layers != 1) {
                    DET_LOGW("buffer metadata mismatch id=%llu",
                             static_cast<unsigned long long>(packet.buffer_id));
                    AHardwareBuffer_release(buffer);
                    break;
                }
                buffers[packet.buffer_id] = buffer;
                registeredPixels += pixels;
                DET_LOGI("registered buffer id=%llu %ux%u stride=%u",
                         static_cast<unsigned long long>(packet.buffer_id),
                         packet.width, packet.height, packet.stride);
                continue;
            }
            if (packet.op == DET_PRESENTER_UNREGISTER) {
                if (received.fence >= 0) break;
                if (auto found = buffers.find(packet.buffer_id);
                    found != buffers.end()) {
                    AHardwareBuffer_Desc description{};
                    AHardwareBuffer_describe(found->second, &description);
                    registeredPixels -= static_cast<uint64_t>(description.width) *
                                        static_cast<uint64_t>(description.height);
                    AHardwareBuffer_release(found->second);
                    buffers.erase(found);
                }
                continue;
            }
            if (packet.op != DET_PRESENTER_PRESENT) {
                DET_LOGW("unknown presenter op=0x%x", packet.op);
                break;
            }
            if (packet.serial == 0 || packet.serial <= lastSerial ||
                connection->inflight.load() >= DET_PRESENTER_MAX_INFLIGHT_FRAMES ||
                !det_presenter_present_flags_valid(packet.flags)) {
                DET_LOGW("rejected present serial=%llu last=%llu inflight=%u",
                         static_cast<unsigned long long>(packet.serial),
                         static_cast<unsigned long long>(lastSerial),
                         connection->inflight.load());
                break;
            }
            const auto found = buffers.find(packet.buffer_id);
            if (found == buffers.end()) {
                DET_LOGW("present of unknown buffer id=%llu",
                         static_cast<unsigned long long>(packet.buffer_id));
                break;
            }
            if ((packet.flags & DET_PRESENTER_HAS_ACQUIRE_FENCE) != 0 &&
                received.fence < 0) {
                DET_LOGW("present serial=%llu missing acquire fence",
                         static_cast<unsigned long long>(packet.serial));
                break;
            }
            if ((packet.flags & DET_PRESENTER_HAS_ACQUIRE_FENCE) == 0 &&
                received.fence >= 0) {
                DET_LOGW("present serial=%llu carried an undeclared fence",
                         static_cast<unsigned long long>(packet.serial));
                break;
            }

            ASurfaceTransaction *transaction = surfaceApi().createTransaction();
            surfaceApi().setVisibility(
                transaction, m_surface, ASURFACE_TRANSACTION_VISIBILITY_SHOW);
            surfaceApi().setZOrder(transaction, m_surface, 1);
            if (surfaceApi().setEnableBackPressure) {
                surfaceApi().setEnableBackPressure(transaction, m_surface, true);
            }
            const ARect source{0, 0, static_cast<int32_t>(packet.width),
                               static_cast<int32_t>(packet.height)};
            const ARect destination{0, 0, m_width.load(), m_height.load()};
            surfaceApi().setGeometry(transaction, m_surface, source,
                                     destination, 0);
            surfaceApi().setBuffer(transaction, m_surface, found->second,
                                   std::exchange(received.fence, -1));
            if (packet.desired_present_time_ns != 0) {
                surfaceApi().setDesiredPresentTime(
                    transaction,
                    static_cast<int64_t>(packet.desired_present_time_ns));
            }
            auto completion = std::make_unique<CompletionContext>();
            completion->connection = connection;
            completion->surface = m_surface;
            completion->serial = packet.serial;
            completion->bufferId = packet.buffer_id;
            completion->releasedBufferId = currentBuffer;
            surfaceApi().acquireSurface(m_surface);
            connection->inflight.fetch_add(1);
            surfaceApi().setOnComplete(transaction, completion.release(),
                                       onComplete);
            surfaceApi().apply(transaction);
            surfaceApi().deleteTransaction(transaction);
            currentBuffer = packet.buffer_id;
            lastSerial = packet.serial;
        }

        for (const auto &[id, buffer] : buffers) {
            (void)id;
            AHardwareBuffer_release(buffer);
        }
        DET_LOGI("guest presenter disconnected");
    }

    std::string m_socketPath;
    ANativeWindow *m_window = nullptr;
    ASurfaceControl *m_surface = nullptr;
    std::atomic<bool> m_running{false};
    std::atomic<int> m_server{-1};
    std::atomic<int> m_client{-1};
    std::atomic<int> m_width;
    std::atomic<int> m_height;
    std::thread m_thread;
};

std::mutex gPresenterMutex;
std::unique_ptr<Presenter> gPresenter;

} // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_com_determination_companion_NativePresenter_nativeStart(
    JNIEnv *env, jobject, jobject surface, jstring socketPath, jint width,
    jint height, jfloat refreshRate)
{
    const char *path = env->GetStringUTFChars(socketPath, nullptr);
    if (!path) {
        return JNI_FALSE;
    }
    try {
        std::lock_guard lock(gPresenterMutex);
        gPresenter.reset();
        gPresenter = std::make_unique<Presenter>(env, surface, path, width,
                                                 height, refreshRate);
        env->ReleaseStringUTFChars(socketPath, path);
        return JNI_TRUE;
    } catch (const std::exception &error) {
        DET_LOGE("presenter start failed: %s", error.what());
        env->ReleaseStringUTFChars(socketPath, path);
        return JNI_FALSE;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_determination_companion_NativePresenter_nativeResize(
    JNIEnv *, jobject, jint width, jint height)
{
    std::lock_guard lock(gPresenterMutex);
    if (gPresenter) {
        gPresenter->resize(width, height);
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_determination_companion_NativePresenter_nativeStop(JNIEnv *, jobject)
{
    std::lock_guard lock(gPresenterMutex);
    gPresenter.reset();
}
