#include "determination/control/transition.hpp"

#include "determination/control/adapter.hpp"
#include "determination/control/system.hpp"

#include <algorithm>
#include <chrono>
#include <iostream>
#include <utility>

namespace determination::control {
namespace {

constexpr std::uint32_t kMinimumDeadlineMs = 5'000;
constexpr std::uint32_t kDefaultDeadlineMs = 120'000;
constexpr std::uint32_t kMaximumDeadlineMs = 300'000;
constexpr std::size_t kJournalOutputLimit = 4096;

bool adapter_succeeded(const AdapterResult &result)
{
    return result.started && !result.timed_out && result.exit_status == 0;
}

std::string bounded_output(const std::string &output)
{
    if (output.size() <= kJournalOutputLimit) return output;
    return output.substr(output.size() - kJournalOutputLimit);
}

} // namespace

TransitionController::TransitionController(std::string root, bool allow_transitions)
    : root_(std::move(root)),
      allow_transitions_(allow_transitions),
      store_(root_ + "/state/control.state")
{
}

TransitionController::~TransitionController()
{
    cancelled_.store(true);
    if (worker_.joinable()) worker_.join();
}

bool TransitionController::initialise(std::string *error)
{
    std::lock_guard lock(mutex_);
    const std::string current_boot = boot_id();
    StateRecord loaded;
    std::string load_error;
    if (!store_.load(&loaded, &load_error)) {
        state_.boot_id = current_boot;
        state_.observed = path_exists(root_ + "/run/desktop-mode")
            ? Mode::Desktop : Mode::Phone;
        state_.desired = state_.observed;
        state_.generation = 1;
        state_.step = "observe";
    } else {
        state_ = std::move(loaded);
        const Mode live = path_exists(root_ + "/run/desktop-mode")
            ? Mode::Desktop : Mode::Phone;
        if (state_.boot_id != current_boot) {
            state_.boot_id = current_boot;
            state_.generation++;
            state_.desired = Mode::Phone;
            state_.observed = live;
            state_.step = "boot-reconcile";
            state_.completed_steps.clear();
            state_.last_error = "previous boot state reconciled to phone baseline";
        } else if (state_.observed == Mode::Entering ||
                   state_.observed == Mode::Exiting) {
            state_.generation++;
            state_.desired = Mode::Phone;
            state_.observed = Mode::Recovery;
            state_.step = "daemon-restart-reconcile";
            state_.last_error = "daemon restarted during an incomplete transition";
        } else if (state_.observed != Mode::Recovery) {
            state_.observed = live;
            state_.desired = live;
        }
    }
    return persist_locked(error);
}

StateRecord TransitionController::snapshot() const
{
    std::lock_guard lock(mutex_);
    return state_;
}

TransitionRequestResult TransitionController::request(
    Mode target, std::uint64_t request_id, std::uint32_t deadline_ms)
{
    TransitionRequestResult result;
    if (!allow_transitions_) {
        result.status = Status::Rejected;
        result.message = "detd is observe-only; use the proven transition path";
        result.state = snapshot();
        return result;
    }
    if (target != Mode::Phone && target != Mode::Desktop) {
        result.status = Status::InvalidRequest;
        result.message = "target must be phone or desktop";
        result.state = snapshot();
        return result;
    }

    {
        std::unique_lock lock(mutex_);
        if (worker_active_) {
            result.status = state_.desired == target ? Status::Accepted : Status::Busy;
            result.message = state_.desired == target
                ? "request coalesced with active transition"
                : "another transition is active";
            result.state = state_;
            return result;
        }
        lock.unlock();
        if (worker_.joinable()) worker_.join();
    }

    std::lock_guard lock(mutex_);
    if (state_.observed == target) {
        result.status = Status::Ok;
        result.message = "already in requested mode";
        result.state = state_;
        return result;
    }

    const std::uint32_t effective_deadline = std::clamp(
        deadline_ms == 0 ? kDefaultDeadlineMs : deadline_ms,
        kMinimumDeadlineMs, kMaximumDeadlineMs);
    state_.generation++;
    state_.transition_id = request_id == 0 ? state_.generation : request_id;
    state_.desired = target;
    state_.observed = target == Mode::Desktop ? Mode::Entering : Mode::Exiting;
    state_.step = "queued";
    state_.completed_steps.clear();
    state_.started_monotonic_ms = monotonic_milliseconds();
    state_.deadline_monotonic_ms = state_.started_monotonic_ms + effective_deadline;
    state_.adapter_status = 0;
    state_.last_error.clear();
    state_.adapter_output.clear();
    std::string save_error;
    if (!persist_locked(&save_error)) {
        state_.observed = Mode::Recovery;
        state_.last_error = "cannot persist transition journal: " + save_error;
        result.status = Status::InternalError;
        result.message = state_.last_error;
        result.state = state_;
        return result;
    }
    cancelled_.store(false);
    worker_active_ = true;
    worker_ = std::thread(&TransitionController::worker, this, target,
                          effective_deadline);
    result.status = Status::Accepted;
    result.message = "transition accepted";
    result.state = state_;
    return result;
}

bool TransitionController::wait_for_idle(std::uint32_t timeout_ms)
{
    std::unique_lock lock(mutex_);
    return idle_condition_.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                                    [this] { return !worker_active_; });
}

bool TransitionController::persist_locked(std::string *error)
{
    std::string local_error;
    if (store_.save(state_, &local_error)) return true;
    if (error) *error = local_error;
    std::cerr << "detd: persist state: " << local_error << '\n';
    return false;
}

void TransitionController::begin_step(const std::string &step)
{
    std::lock_guard lock(mutex_);
    state_.step = step;
    persist_locked();
}

void TransitionController::complete_step(const std::string &step,
                                         int adapter_status,
                                         const std::string &output)
{
    std::lock_guard lock(mutex_);
    state_.completed_steps.push_back(step);
    state_.adapter_status = adapter_status;
    state_.adapter_output = bounded_output(output);
    persist_locked();
}

bool TransitionController::verify_target(Mode target, std::string *error) const
{
    const bool marker = path_exists(root_ + "/run/desktop-mode");
    const std::string sf = android_property("init.svc.surfaceflinger");
    if (target == Mode::Desktop) {
        if (!marker) {
            *error = "desktop marker is absent after enter adapter";
            return false;
        }
        if (!sf.empty() && sf != "stopped") {
            *error = "SurfaceFlinger is " + sf + " after enter adapter";
            return false;
        }
        return true;
    }
    if (marker) {
        *error = "desktop marker remains after phone restore";
        return false;
    }
    if (!sf.empty() && sf != "running") {
        *error = "SurfaceFlinger is " + sf + " after phone restore";
        return false;
    }
    return true;
}

void TransitionController::fail_transition(
    const std::string &step, int adapter_status, const std::string &message,
    const std::string &output, bool attempt_rollback)
{
    const std::string original_error = step + ": " + message;
    if (attempt_rollback && !cancelled_.load()) {
        begin_step("rollback-desktop-off");
        const AdapterResult rollback = run_adapter(
            root_ + "/bin/desktop-off", {}, std::chrono::seconds(60),
            64U * 1024U, &cancelled_);
        std::string verify_error;
        if (adapter_succeeded(rollback) && verify_target(Mode::Phone, &verify_error)) {
            std::lock_guard lock(mutex_);
            state_.completed_steps.push_back("rollback-desktop-off");
            state_.desired = Mode::Phone;
            state_.observed = Mode::Phone;
            state_.step = "rollback-complete";
            state_.adapter_status = adapter_status;
            state_.adapter_output = bounded_output(output + "\n" + rollback.output);
            state_.last_error = original_error;
            state_.started_monotonic_ms = 0;
            state_.deadline_monotonic_ms = 0;
            persist_locked();
            worker_active_ = false;
            idle_condition_.notify_all();
            return;
        }
    }

    std::string phone_error;
    const bool phone_safe = verify_target(Mode::Phone, &phone_error);
    std::lock_guard lock(mutex_);
    state_.desired = Mode::Phone;
    state_.observed = phone_safe ? Mode::Phone : Mode::Recovery;
    state_.step = phone_safe ? "failed-phone-safe" : "recovery-required";
    state_.adapter_status = adapter_status;
    state_.adapter_output = bounded_output(output);
    state_.last_error = original_error;
    if (!phone_safe && !phone_error.empty()) {
        state_.last_error += "; " + phone_error;
    }
    if (phone_safe) {
        state_.started_monotonic_ms = 0;
        state_.deadline_monotonic_ms = 0;
    }
    persist_locked();
    worker_active_ = false;
    idle_condition_.notify_all();
}

void TransitionController::worker(Mode target, std::uint64_t deadline_ms)
{
    const auto remaining = [this, deadline_ms]() {
        const std::uint64_t now = monotonic_milliseconds();
        StateRecord state = snapshot();
        if (state.deadline_monotonic_ms <= now) return std::chrono::milliseconds(1);
        const std::uint64_t left = state.deadline_monotonic_ms - now;
        return std::chrono::milliseconds(std::min<std::uint64_t>(left, deadline_ms));
    };

    if (target == Mode::Desktop) {
        begin_step("guest-start");
        const AdapterResult guest = run_adapter(
            root_ + "/bin/guest-start", {}, remaining(), 64U * 1024U, &cancelled_);
        if (!adapter_succeeded(guest)) {
            fail_transition("guest-start", guest.exit_status,
                            guest.error.empty() ? "adapter failed" : guest.error,
                            guest.output, false);
            return;
        }
        complete_step("guest-start", guest.exit_status, guest.output);

        begin_step("desktop-on");
        const AdapterResult enter = run_adapter(
            root_ + "/bin/desktop-on", {}, remaining(), 64U * 1024U, &cancelled_);
        if (!adapter_succeeded(enter)) {
            fail_transition("desktop-on", enter.exit_status,
                            enter.error.empty() ? "adapter failed" : enter.error,
                            enter.output, true);
            return;
        }
        complete_step("desktop-on", enter.exit_status, enter.output);
        std::string verify_error;
        if (!verify_target(Mode::Desktop, &verify_error)) {
            fail_transition("verify-desktop", 0, verify_error, enter.output, true);
            return;
        }
    } else {
        begin_step("desktop-off");
        const AdapterResult exit = run_adapter(
            root_ + "/bin/desktop-off", {}, remaining(), 64U * 1024U, &cancelled_);
        if (!adapter_succeeded(exit)) {
            fail_transition("desktop-off", exit.exit_status,
                            exit.error.empty() ? "adapter failed" : exit.error,
                            exit.output, false);
            return;
        }
        complete_step("desktop-off", exit.exit_status, exit.output);
        std::string verify_error;
        if (!verify_target(Mode::Phone, &verify_error)) {
            fail_transition("verify-phone", 0, verify_error, exit.output, false);
            return;
        }
    }

    std::lock_guard lock(mutex_);
    state_.observed = target;
    state_.desired = target;
    state_.step = "idle";
    state_.adapter_status = 0;
    state_.last_error.clear();
    state_.adapter_output.clear();
    state_.started_monotonic_ms = 0;
    state_.deadline_monotonic_ms = 0;
    persist_locked();
    worker_active_ = false;
    idle_condition_.notify_all();
}

} // namespace determination::control
