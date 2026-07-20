#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace determination::control {

std::uint64_t monotonic_milliseconds();
std::string read_file(const std::string &path, std::size_t limit = 64U * 1024U);
std::string trim(std::string value);
std::string json_escape(const std::string &value);
std::string boot_id();
std::string android_property(const std::string &name);
char process_state(const std::string &name);
bool path_exists(const std::string &path);
bool ensure_directory(const std::string &path, unsigned int mode,
                      std::string *error);
bool atomic_write_file(const std::string &path, const std::string &value,
                       unsigned int mode, std::string *error);
std::uint64_t fnv1a64(const std::string &value);

} // namespace determination::control
