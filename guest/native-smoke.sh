#!/system/bin/sh
# M5 native-DRM track, Phase 0 verdict: does the Mesa-native stack hold
# together on this device WITHOUT touching the display?
#   1. Turnip enumerates on kgsl        (build-mesa.sh output, /opt/mesa)
#   2. minigbm allocates/maps/exports   (build-minigbm.sh output, /opt/minigbm)
#   3. a minigbm dmabuf IMPORTS into Turnip — the zero-copy seam every later
#      phase (compositor swapchain, Phase 2 AHardwareBuffer bridge) rests on
#   4. (informational) zink GL identity via surfaceless EGL
# Run ON THE PHONE as root, any mode — nothing display-visible here.
#   adb shell "su -c 'sh /data/local/tmp/native-smoke.sh'" \
#       | tee artifacts/native-smoke-$(date +%Y%m%d).txt
set -u
DET=/data/determination
LXC="$DET/lxc/bin/lxc-attach -P $DET -n guest --"

exec $LXC /bin/sh -c '
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export TMPDIR=/tmp
    fail=0
    [ -f /opt/mesa/env.sh ] || { echo "FATAL: /opt/mesa missing — run guest/build-mesa.sh first"; exit 2; }
    . /opt/mesa/env.sh
    export LD_LIBRARY_PATH=/opt/minigbm/lib:$LD_LIBRARY_PATH

    echo "== 1. Turnip on kgsl =="
    if vulkaninfo --summary 2>/tmp/vk.err | tee /tmp/vk.out | grep -i "turnip"; then
        echo "TURNIP: OK"
    else
        echo "TURNIP: FAIL (see /tmp/vk.err)"; tail -5 /tmp/vk.err; fail=1
    fi

    echo "== 2. minigbm probe =="
    if [ -x /opt/minigbm/bin/gbm-probe ] && /opt/minigbm/bin/gbm-probe; then
        echo "MINIGBM: OK"
    else
        echo "MINIGBM: FAIL — run guest/build-minigbm.sh"; fail=1
    fi

    echo "== 3. minigbm dmabuf -> Turnip import =="
    mkdir -p /root/native-probe
    cat > /root/native-probe/vk-import.c <<"CEOF"
/* The seam test: allocate with minigbm, export dmabuf, import into a
 * VkDeviceMemory on Turnip and bind it to a VkBuffer. Proves external-memory
 * interop between the two allocators lives (kgsl <-> ion/GEM dmabufs). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <gbm.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { \
    printf("VK-IMPORT: FAIL %s = %d\n", #x, r_); return 1; } } while (0)

int main(void)
{
    /* -- minigbm side -- */
    int nfd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (nfd < 0) nfd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (nfd < 0) { printf("VK-IMPORT: FAIL no drm node\n"); return 1; }
    struct gbm_device *gdev = gbm_create_device(nfd);
    if (!gdev) { printf("VK-IMPORT: FAIL gbm_create_device\n"); return 1; }
    struct gbm_bo *bo = gbm_bo_create(gdev, 256, 256, GBM_FORMAT_ARGB8888,
                                      GBM_BO_USE_LINEAR | GBM_BO_USE_RENDERING);
    if (!bo) { printf("VK-IMPORT: FAIL gbm_bo_create\n"); return 1; }
    int dmabuf = gbm_bo_get_fd(bo);
    if (dmabuf < 0) { printf("VK-IMPORT: FAIL gbm_bo_get_fd\n"); return 1; }
    off_t bufsz = lseek(dmabuf, 0, SEEK_END);
    printf("gbm: backend=%s dmabuf fd=%d size=%lld stride=%u\n",
           gbm_device_get_backend_name(gdev), dmabuf, (long long)bufsz,
           gbm_bo_get_stride(bo));

    /* -- vulkan side -- */
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                              .apiVersion = VK_API_VERSION_1_1 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                                 .pApplicationInfo = &app };
    VkInstance inst; CK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t n = 1; VkPhysicalDevice pd;
    CK(vkEnumeratePhysicalDevices(inst, &n, &pd));
    if (n == 0) { printf("VK-IMPORT: FAIL no physical device\n"); return 1; }
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(pd, &props);
    printf("vk: device=%s\n", props.deviceName);

    const char *exts[] = { "VK_KHR_external_memory_fd",
                           "VK_EXT_external_memory_dma_buf" };
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
        .enabledExtensionCount = 2, .ppEnabledExtensionNames = exts };
    VkDevice dev; CK(vkCreateDevice(pd, &dci, NULL, &dev));

    PFN_vkGetMemoryFdPropertiesKHR getFdProps =
        (PFN_vkGetMemoryFdPropertiesKHR)vkGetDeviceProcAddr(dev, "vkGetMemoryFdPropertiesKHR");
    VkMemoryFdPropertiesKHR fdp = { .sType = VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR };
    CK(getFdProps(dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, dmabuf, &fdp));
    printf("vk: dmabuf memoryTypeBits=0x%x\n", fdp.memoryTypeBits);

    VkExternalMemoryBufferCreateInfo emb = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
        .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
    VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = &emb, .size = (VkDeviceSize)bufsz,
        .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    VkBuffer buf; CK(vkCreateBuffer(dev, &bci, NULL, &buf));
    VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev, buf, &mr);

    uint32_t bits = mr.memoryTypeBits & fdp.memoryTypeBits, idx = 0;
    while (bits && !(bits & 1)) { bits >>= 1; idx++; }
    if (!bits) { printf("VK-IMPORT: FAIL no compatible memory type\n"); return 1; }

    VkImportMemoryFdInfoKHR imp = {
        .sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
        .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        .fd = dup(dmabuf) };
    VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &imp, .allocationSize = (VkDeviceSize)bufsz,
        .memoryTypeIndex = idx };
    VkDeviceMemory mem; CK(vkAllocateMemory(dev, &mai, NULL, &mem));
    CK(vkBindBufferMemory(dev, buf, mem, 0));
    printf("VK-IMPORT: PASS (bound %lld-byte minigbm dmabuf as VkBuffer on %s)\n",
           (long long)bufsz, props.deviceName);
    return 0;
}
CEOF
    if gcc -O2 -o /root/native-probe/vk-import /root/native-probe/vk-import.c \
            -I/opt/minigbm/include -L/opt/minigbm/lib -Wl,-rpath,/opt/minigbm/lib \
            -lgbm -lvulkan 2>/tmp/vkimp-cc.err; then
        /root/native-probe/vk-import || fail=1
    else
        echo "VK-IMPORT: FAIL (compile)"; tail -10 /tmp/vkimp-cc.err; fail=1
    fi

    echo "== 4. zink GL identity (informational) =="
    if command -v eglinfo >/dev/null; then
        EGL_PLATFORM=surfaceless eglinfo -B 2>/dev/null | grep -iE "zink|renderer|version" | head -6 \
            || echo "zink surfaceless: no output (not fatal at this phase)"
    else
        echo "SKIP: eglinfo not installed (apt install mesa-utils-bin)"
    fi

    echo "== VERDICT =="
    [ "$fail" = 0 ] && echo "NATIVE-SMOKE: ALL PASS" || echo "NATIVE-SMOKE: FAILURES (see above)"
    exit $fail
'
