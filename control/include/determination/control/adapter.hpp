#pragma once

#include <chrono>
#include <cstddef>
#include <atomic>
#include <string>
#include <vector>

namespace determination::control {

struct AdapterResult {
    bool started = false;
    bool timed_out = false;
    int exit_status = -1;
    std::string output;
    std::string error;
};

AdapterResult run_adapter(const std::string &path,
                          const std::vector<std::string> &arguments,
                          std::chrono::milliseconds timeout,
                          std::size_t output_limit = 64U * 1024U,
                          const std::atomic<bool> *cancelled = nullptr);

} // namespace determination::control
