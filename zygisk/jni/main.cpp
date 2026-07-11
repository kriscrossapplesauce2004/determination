// Determination Zygisk module — SF-death suppression hook.
// PLT-hooks __system_property_set in system_server: when desktop-mode is
// active, swallows ctl.start/ctl.restart for surfaceflinger so the stopped
// SF stays stopped (replacing the shell suppressor loop in desktop-on).

#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#include "zygisk.hpp"

static constexpr const char *FLAG = "/data/determination/run/desktop-mode";
static int (*orig_system_property_set)(const char *, const char *) = nullptr;

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

public:
    void onLoad(zygisk::Api *api, JNIEnv *) override {
        api_ = api;
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *) override {
        api_->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
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
