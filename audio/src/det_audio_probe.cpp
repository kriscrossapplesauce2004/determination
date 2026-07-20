#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <vector>

namespace {

struct Node {
    std::string path;
    std::string type;
    unsigned int major_number = 0;
    unsigned int minor_number = 0;
    unsigned int mode = 0;
    unsigned int uid = 0;
    unsigned int gid = 0;
};

struct Holder {
    int pid = 0;
    int fd = 0;
    std::string comm;
    std::string cmdline;
    std::string target;
};

struct ProcFile {
    std::string name;
    std::string content;
};

struct Inventory {
    std::string root;
    std::vector<Node> nodes;
    std::vector<Holder> holders;
    std::vector<ProcFile> proc_files;
};

[[nodiscard]] std::string join_root(const std::string &root,
                                    std::string_view absolute) {
    if (root == "/") return std::string(absolute);
    return root + std::string(absolute);
}

[[nodiscard]] std::optional<std::string> read_file(const std::string &path,
                                                   bool binary = false) {
    std::ifstream stream(path, binary ? std::ios::binary : std::ios::in);
    if (!stream) return std::nullopt;
    std::ostringstream out;
    out << stream.rdbuf();
    return out.str();
}

[[nodiscard]] std::string json_escape(std::string_view input) {
    std::ostringstream out;
    for (const unsigned char ch : input) {
        switch (ch) {
        case '"': out << "\\\""; break;
        case '\\': out << "\\\\"; break;
        case '\b': out << "\\b"; break;
        case '\f': out << "\\f"; break;
        case '\n': out << "\\n"; break;
        case '\r': out << "\\r"; break;
        case '\t': out << "\\t"; break;
        default:
            if (ch < 0x20) {
                constexpr char hex[] = "0123456789abcdef";
                out << "\\u00" << hex[(ch >> 4U) & 0xfU] << hex[ch & 0xfU];
            } else {
                out << static_cast<char>(ch);
            }
        }
    }
    return out.str();
}

[[nodiscard]] bool digits_only(std::string_view input) {
    return !input.empty() && std::all_of(input.begin(), input.end(), [](char ch) {
        return std::isdigit(static_cast<unsigned char>(ch)) != 0;
    });
}

[[nodiscard]] std::vector<std::string> directory_entries(const std::string &path) {
    std::vector<std::string> names;
    DIR *dir = opendir(path.c_str());
    if (dir == nullptr) return names;
    while (dirent *entry = readdir(dir)) {
        const std::string name(entry->d_name);
        if (name != "." && name != "..") names.push_back(name);
    }
    closedir(dir);
    std::sort(names.begin(), names.end());
    return names;
}

[[nodiscard]] std::optional<std::string> read_link(const std::string &path) {
    std::vector<char> buffer(4096);
    const ssize_t length = readlink(path.c_str(), buffer.data(), buffer.size() - 1U);
    if (length < 0) return std::nullopt;
    buffer[static_cast<size_t>(length)] = '\0';
    return std::string(buffer.data(), static_cast<size_t>(length));
}

[[nodiscard]] std::string node_type(const std::string &name) {
    if (name.rfind("controlC", 0) == 0) return "control";
    if (name.rfind("pcmC", 0) == 0) return "pcm";
    if (name.rfind("comprC", 0) == 0) return "compress";
    if (name.rfind("hwC", 0) == 0) return "hardware-dependent";
    if (name == "seq") return "sequencer";
    if (name == "timer") return "timer";
    return "other";
}

void collect_nodes(Inventory &inventory) {
    const std::string directory = join_root(inventory.root, "/dev/snd");
    for (const std::string &name : directory_entries(directory)) {
        const std::string real_path = directory + "/" + name;
        struct stat info {};
        if (lstat(real_path.c_str(), &info) != 0) continue;
        Node node;
        node.path = "/dev/snd/" + name;
        node.type = node_type(name);
        node.mode = static_cast<unsigned int>(info.st_mode & 07777U);
        node.uid = static_cast<unsigned int>(info.st_uid);
        node.gid = static_cast<unsigned int>(info.st_gid);
        if (S_ISCHR(info.st_mode) || S_ISBLK(info.st_mode)) {
            node.major_number = major(info.st_rdev);
            node.minor_number = minor(info.st_rdev);
        }
        inventory.nodes.push_back(std::move(node));
    }
}

void collect_proc_files(Inventory &inventory) {
    constexpr std::string_view names[] = {
        "version", "cards", "devices", "pcm", "modules", "timers"
    };
    for (const auto name : names) {
        const auto content = read_file(join_root(inventory.root,
                                                std::string("/proc/asound/") +
                                                    std::string(name)));
        if (content) inventory.proc_files.push_back({std::string(name), *content});
    }
}

[[nodiscard]] bool is_audio_target(std::string_view target) {
    return target.rfind("/dev/snd/", 0) == 0;
}

void collect_holders(Inventory &inventory) {
    const std::string proc = join_root(inventory.root, "/proc");
    for (const std::string &pid_name : directory_entries(proc)) {
        if (!digits_only(pid_name)) continue;
        const std::string process = proc + "/" + pid_name;
        for (const std::string &fd_name : directory_entries(process + "/fd")) {
            if (!digits_only(fd_name)) continue;
            const auto target = read_link(process + "/fd/" + fd_name);
            if (!target || !is_audio_target(*target)) continue;

            Holder holder;
            holder.pid = std::stoi(pid_name);
            holder.fd = std::stoi(fd_name);
            holder.target = *target;
            holder.comm = read_file(process + "/comm").value_or("");
            while (!holder.comm.empty() &&
                   (holder.comm.back() == '\n' || holder.comm.back() == '\r')) {
                holder.comm.pop_back();
            }
            holder.cmdline = read_file(process + "/cmdline", true).value_or("");
            std::replace(holder.cmdline.begin(), holder.cmdline.end(), '\0', ' ');
            while (!holder.cmdline.empty() && holder.cmdline.back() == ' ') {
                holder.cmdline.pop_back();
            }
            inventory.holders.push_back(std::move(holder));
        }
    }
    std::sort(inventory.holders.begin(), inventory.holders.end(),
              [](const Holder &left, const Holder &right) {
                  if (left.pid != right.pid) return left.pid < right.pid;
                  return left.fd < right.fd;
              });
}

[[nodiscard]] Inventory collect(std::string root) {
    while (root.size() > 1U && root.back() == '/') root.pop_back();
    Inventory inventory;
    inventory.root = std::move(root);
    collect_nodes(inventory);
    collect_proc_files(inventory);
    collect_holders(inventory);
    return inventory;
}

void print_json(const Inventory &inventory) {
    std::cout << "{\"schema\":1,\"root\":\"" << json_escape(inventory.root)
              << "\",\"nodes\":[";
    for (size_t index = 0; index < inventory.nodes.size(); ++index) {
        if (index != 0U) std::cout << ',';
        const Node &node = inventory.nodes[index];
        std::ostringstream mode;
        mode << std::oct << node.mode;
        std::cout << "{\"path\":\"" << json_escape(node.path)
                  << "\",\"type\":\"" << json_escape(node.type)
                  << "\",\"major\":" << node.major_number
                  << ",\"minor\":" << node.minor_number
                  << ",\"mode\":\"" << mode.str()
                  << "\",\"uid\":" << node.uid
                  << ",\"gid\":" << node.gid << '}';
    }
    std::cout << "],\"holders\":[";
    for (size_t index = 0; index < inventory.holders.size(); ++index) {
        if (index != 0U) std::cout << ',';
        const Holder &holder = inventory.holders[index];
        std::cout << "{\"pid\":" << holder.pid
                  << ",\"fd\":" << holder.fd
                  << ",\"comm\":\"" << json_escape(holder.comm)
                  << "\",\"cmdline\":\"" << json_escape(holder.cmdline)
                  << "\",\"target\":\"" << json_escape(holder.target) << "\"}";
    }
    std::cout << "],\"proc\":{";
    for (size_t index = 0; index < inventory.proc_files.size(); ++index) {
        if (index != 0U) std::cout << ',';
        const ProcFile &file = inventory.proc_files[index];
        std::cout << '"' << json_escape(file.name) << "\":\""
                  << json_escape(file.content) << '"';
    }
    std::cout << "},\"summary\":{\"node_count\":" << inventory.nodes.size()
              << ",\"holder_count\":" << inventory.holders.size()
              << ",\"hardware_unowned\":"
              << (inventory.holders.empty() ? "true" : "false") << "}}\n";
}

void print_human(const Inventory &inventory) {
    std::cout << "ALSA nodes: " << inventory.nodes.size() << '\n';
    for (const Node &node : inventory.nodes) {
        std::cout << "  " << node.path << "  " << node.type << "  "
                  << node.major_number << ':' << node.minor_number << "  uid="
                  << node.uid << " gid=" << node.gid << '\n';
    }
    std::cout << "Open hardware descriptors: " << inventory.holders.size() << '\n';
    for (const Holder &holder : inventory.holders) {
        std::cout << "  pid=" << holder.pid << " fd=" << holder.fd << " "
                  << holder.comm << " -> " << holder.target << '\n';
    }
    std::cout << "Hardware ownership gate: "
              << (inventory.holders.empty() ? "UNOWNED" : "BUSY") << '\n';
}

void usage(std::ostream &out) {
    out << "usage: det-audio-probe [--human] [--require-unowned] [--root PATH]\n"
           "\n"
           "Read-only direct-audio inventory. Reports /dev/snd, /proc/asound and\n"
           "every process descriptor holding ALSA hardware. --require-unowned\n"
           "returns 3 while any holder remains; it never stops services or opens PCM.\n";
}

} // namespace

int main(int argc, char **argv) {
    std::string root = "/";
    bool human = false;
    bool require_unowned = false;
    for (int index = 1; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        if (argument == "--help" || argument == "-h") {
            usage(std::cout);
            return 0;
        }
        if (argument == "--human") {
            human = true;
            continue;
        }
        if (argument == "--require-unowned") {
            require_unowned = true;
            continue;
        }
        if (argument == "--root" && index + 1 < argc) {
            root = argv[++index];
            continue;
        }
        std::cerr << "unknown or incomplete argument: " << argument << '\n';
        usage(std::cerr);
        return 2;
    }

    const Inventory inventory = collect(root);
    if (human) print_human(inventory); else print_json(inventory);
    if (require_unowned && !inventory.holders.empty()) return 3;
    return 0;
}
