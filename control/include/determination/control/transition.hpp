#pragma once

#include "determination/control/protocol.hpp"
#include "determination/control/state.hpp"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

namespace determination::control {

struct TransitionRequestResult {
    Status status = Status::InternalError;
    std::string message;
    StateRecord state;
};

class TransitionController {
public:
    TransitionController(std::string root, bool allow_transitions);
    ~TransitionController();

    TransitionController(const TransitionController &) = delete;
    TransitionController &operator=(const TransitionController &) = delete;

    bool initialise(std::string *error);
    StateRecord snapshot() const;
    TransitionRequestResult request(Mode target, std::uint64_t request_id,
                                    std::uint32_t deadline_ms);
    bool wait_for_idle(std::uint32_t timeout_ms);
    bool allow_transitions() const { return allow_transitions_; }

private:
    void worker(Mode target, std::uint64_t deadline_ms);
    bool persist_locked(std::string *error = nullptr);
    void begin_step(const std::string &step);
    void complete_step(const std::string &step, int adapter_status,
                       const std::string &output);
    void fail_transition(const std::string &step, int adapter_status,
                         const std::string &message, const std::string &output,
                         bool attempt_rollback);
    bool verify_target(Mode target, std::string *error) const;

    std::string root_;
    bool allow_transitions_ = false;
    StateStore store_;
    mutable std::mutex mutex_;
    std::condition_variable idle_condition_;
    StateRecord state_;
    std::thread worker_;
    std::atomic<bool> cancelled_{false};
    bool worker_active_ = false;
};

} // namespace determination::control
