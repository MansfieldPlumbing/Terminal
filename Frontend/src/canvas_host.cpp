// directport.android.vulkan.cpp
// DirectPort — Vulkan IPC Fabric
// Target : Android Bionic · ARMv8-A 64-bit (arm64-v8a)
//
// Direct translation of directportd3d12.cpp. API surface is preserved
// with the following mechanical substitutions:
//
//   D3D12 concept                  Vulkan equivalent
//   ─────────────────────────────  ────────────────────────────────────────
//   ID3D12Device                   VkDevice (+ VkInstance / VkPhysicalDevice)
//   ID3D12Resource (Texture2D)     VkImage  + VkDeviceMemory
//   ID3D12Fence (value-based)      VkSemaphore (timeline, KHR)
//   HANDLE (NT named object)       int fd   (opaque Unix fd, POSIX)
//   HANDLE hEvent + WaitForSingle  vkWaitSemaphoresKHR  (CPU block, no extra event object)
//   pQueue->Wait(fence, val)       vkQueueSubmit with timeline wait semaphore
//   resource->Map()                vkMapMemory  (HOST_VISIBLE memory only)
//   GetCopyableFootprints / manual  vkGetImageSubresourceLayout (authoritative pitch)
//   CUSTOM heap (ROW_MAJOR)        VK_IMAGE_TILING_LINEAR + HOST_VISIBLE | HOST_COHERENT
//   DEFAULT heap (VRAM)            VK_IMAGE_TILING_OPTIMAL + DEVICE_LOCAL
//   HeapAlloc / HeapFree           malloc / free
//   wchar_t* object name           int* out_fd  (create) / int fd (open)
//   SECURITY_ATTRIBUTES / SDDL     n/a — fd permissions are Unix DAC
//
// CROSS-PROCESS SHARING MODEL
//   NT's named object namespace is replaced by Unix file descriptors.
//   dp_vk_create_shared_resource writes the exported image and semaphore
//   fds into *out_image_fd and *out_semaphore_fd.  The caller is responsible
//   for transmitting those fds to the consumer process via SCM_RIGHTS over
//   a Unix domain socket (sendmsg/recvmsg).  dp_vk_open_shared_resource
//   takes the received fds.  This is the idiomatic Android IPC path; Binder
//   also works but SCM_RIGHTS maps most directly to the NT model.
//
//   NOTE: Vulkan opaque fds carry no image metadata.  dp_vk_open_shared_resource
//   therefore requires the consumer to supply width/height/format/is_cpu_mappable
//   — the same values used at creation time — so the VkImage can be created with
//   matching parameters before the memory fd is imported.
//
// REQUIRED EXTENSIONS
//   Instance : VK_KHR_get_physical_device_properties2
//              VK_KHR_external_memory_capabilities
//              VK_KHR_external_semaphore_capabilities
//   Device   : VK_KHR_external_memory
//              VK_KHR_external_memory_fd
//              VK_KHR_external_semaphore
//              VK_KHR_external_semaphore_fd
//              VK_KHR_timeline_semaphore
//   All are promoted to Vulkan 1.2 core, available on all Android Vulkan 1.1+
//   drivers (API level 28+).
//
// ARCHITECTURAL NOTE (v1.0 constraint): g_dpvk_device is a single global adapter.
// Mirrors the D3D12 version's constraint.  Multi-card deployments must refactor
// to pass VkDevice explicitly at init or handle creation time.
//
// BUILD (Android NDK CMake)
//   find_package(Vulkan REQUIRED)
//   target_link_libraries(<target> Vulkan::Vulkan android log)
//   No #pragma comment(lib) on Bionic; linker is driven by CMakeLists.

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>
#include <android/log.h>

#include "directport.h"

#define DP_LOG_TAG  "DirectPort"
#define DPLOGE(...) __android_log_print(ANDROID_LOG_ERROR,  DP_LOG_TAG, __VA_ARGS__)
#define DPLOGI(...) __android_log_print(ANDROID_LOG_INFO,   DP_LOG_TAG, __VA_ARGS__)

// ─── PFN TRAMPOLINES ─────────────────────────────────────────────────────────
// KHR extension entry points are not in the static loader on all Android
// versions; resolve them once at dp_vk_init time.
static PFN_vkGetMemoryFdKHR              pfn_vkGetMemoryFdKHR              = NULL;
static PFN_vkGetSemaphoreFdKHR           pfn_vkGetSemaphoreFdKHR           = NULL;
static PFN_vkImportSemaphoreFdKHR        pfn_vkImportSemaphoreFdKHR        = NULL;
static PFN_vkWaitSemaphoresKHR           pfn_vkWaitSemaphoresKHR           = NULL;
static PFN_vkSignalSemaphoreKHR          pfn_vkSignalSemaphoreKHR          = NULL;
static PFN_vkGetSemaphoreCounterValueKHR pfn_vkGetSemaphoreCounterValueKHR = NULL;

// ─── GLOBAL SINGLETON ────────────────────────────────────────────────────────
static VkInstance       g_dpvk_instance  = VK_NULL_HANDLE;
static VkPhysicalDevice g_dpvk_phys      = VK_NULL_HANDLE;
static VkDevice         g_dpvk_device    = VK_NULL_HANDLE;
static uint32_t         g_dpvk_qfam      = UINT32_MAX;

// ─── HANDLE STATE ─────────────────────────────────────────────────────────────
typedef struct {
    VkImage        image;
    VkDeviceMemory memory;
    VkSemaphore    semaphore;      // timeline semaphore — value-based, mirrors ID3D12Fence
    int            image_fd;       // exported opaque fd (-1 = consumer/not exported)
    int            semaphore_fd;   // exported opaque fd (-1 = consumer/not exported)
    bool           is_cpu_mappable;
    VkDeviceSize   row_pitch;      // from vkGetImageSubresourceLayout; 0 until first map
} DPVk_State;

// ─── FORMAT MAP ───────────────────────────────────────────────────────────────
static VkFormat dp_to_vk_format(DP_FORMAT fmt) {
    switch (fmt) {
        case DP_FORMAT_VIDEO:     return VK_FORMAT_B8G8R8A8_UNORM;
        case DP_FORMAT_FLOAT:     return VK_FORMAT_R32_SFLOAT;
        case DP_FORMAT_HALF:      return VK_FORMAT_R16_SFLOAT;
        case DP_FORMAT_RAW_32BIT: return VK_FORMAT_R32_UINT;
        default:                  return VK_FORMAT_UNDEFINED;
    }
}

// ─── INTERNAL HELPERS ─────────────────────────────────────────────────────────
static uint32_t find_memory_type(VkMemoryPropertyFlags required, uint32_t type_bits) {
    VkPhysicalDeviceMemoryProperties props;
    vkGetPhysicalDeviceMemoryProperties(g_dpvk_phys, &props);
    for (uint32_t i = 0; i < props.memoryTypeCount; ++i) {
        if ((type_bits & (1u << i)) &&
            (props.memoryTypes[i].propertyFlags & required) == required)
            return i;
    }
    return UINT32_MAX;
}

// Creates a VkImage with external memory export annotation.
// Tiling follows is_cpu_mappable: LINEAR for host access, OPTIMAL for GPU-only.
static VkImage create_image(uint32_t width, uint32_t height, VkFormat fmt,
                             bool is_cpu_mappable, VkMemoryRequirements* out_req) {
    VkExternalMemoryImageCreateInfo ext_info = {
        .sType       = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
    };
    VkImageCreateInfo ci = {
        .sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext         = &ext_info,
        .imageType     = VK_IMAGE_TYPE_2D,
        .format        = fmt,
        .extent        = { width, height, 1 },
        .mipLevels     = 1,
        .arrayLayers   = 1,
        .samples       = VK_SAMPLE_COUNT_1_BIT,
        // LINEAR required for HOST_VISIBLE CPU access; OPTIMAL for DEVICE_LOCAL.
        // Mirrors D3D12: ROW_MAJOR (CUSTOM heap) vs LAYOUT_UNKNOWN (DEFAULT heap).
        .tiling        = is_cpu_mappable ? VK_IMAGE_TILING_LINEAR
                                         : VK_IMAGE_TILING_OPTIMAL,
        .usage         = VK_IMAGE_USAGE_STORAGE_BIT
                       | VK_IMAGE_USAGE_SAMPLED_BIT
                       | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
                       | VK_IMAGE_USAGE_TRANSFER_SRC_BIT
                       | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .sharingMode   = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    VkImage image = VK_NULL_HANDLE;
    if (vkCreateImage(g_dpvk_device, &ci, NULL, &image) != VK_SUCCESS)
        return VK_NULL_HANDLE;
    vkGetImageMemoryRequirements(g_dpvk_device, image, out_req);
    return image;
}

// Allocates and binds exportable device memory for image.
static VkDeviceMemory alloc_and_bind(VkImage image, VkMemoryRequirements* req,
                                     VkMemoryPropertyFlags props_required) {
    VkExportMemoryAllocateInfo exp = {
        .sType       = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
        .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
    };
    uint32_t mtype = find_memory_type(props_required, req->memoryTypeBits);
    if (mtype == UINT32_MAX) return VK_NULL_HANDLE;

    VkMemoryAllocateInfo ai = {
        .sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext           = &exp,
        .allocationSize  = req->size,
        .memoryTypeIndex = mtype,
    };
    VkDeviceMemory mem = VK_NULL_HANDLE;
    if (vkAllocateMemory(g_dpvk_device, &ai, NULL, &mem) != VK_SUCCESS)
        return VK_NULL_HANDLE;
    if (vkBindImageMemory(g_dpvk_device, image, mem, 0) != VK_SUCCESS) {
        vkFreeMemory(g_dpvk_device, mem, NULL);
        return VK_NULL_HANDLE;
    }
    return mem;
}

// Creates a timeline semaphore with export capability.
// Mirrors ID3D12Fence with D3D12_FENCE_FLAG_SHARED | SHARED_CROSS_ADAPTER.
static VkSemaphore create_timeline_semaphore(void) {
    VkExportSemaphoreCreateInfo exp = {
        .sType       = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
        .handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT,
    };
    VkSemaphoreTypeCreateInfo type_info = {
        .sType         = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
        .pNext         = &exp,
        .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
        .initialValue  = 0,
    };
    VkSemaphoreCreateInfo sci = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = &type_info,
    };
    VkSemaphore sem = VK_NULL_HANDLE;
    vkCreateSemaphore(g_dpvk_device, &sci, NULL, &sem);
    return sem;
}

// ─── GLOBAL SUBSYSTEM LIFECYCLE ───────────────────────────────────────────────
DP_EXPORT bool dp_vk_init(void) {
    if (g_dpvk_device != VK_NULL_HANDLE) return true;

    const char* inst_exts[] = {
        VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
        VK_KHR_EXTERNAL_MEMORY_CAPABILITIES_EXTENSION_NAME,
        VK_KHR_EXTERNAL_SEMAPHORE_CAPABILITIES_EXTENSION_NAME,
    };
    VkInstanceCreateInfo ici = {
        .sType                   = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .enabledExtensionCount   = 3,
        .ppEnabledExtensionNames = inst_exts,
    };
    if (vkCreateInstance(&ici, NULL, &g_dpvk_instance) != VK_SUCCESS) {
        DPLOGE("vkCreateInstance failed");
        return false;
    }

    // Pick first physical device — mirrors D3D12CreateDevice(NULL, ...).
    uint32_t dev_count = 1;
    if (vkEnumeratePhysicalDevices(g_dpvk_instance, &dev_count, &g_dpvk_phys) != VK_SUCCESS
        || dev_count == 0) {
        DPLOGE("No physical devices");
        vkDestroyInstance(g_dpvk_instance, NULL);
        g_dpvk_instance = VK_NULL_HANDLE;
        return false;
    }

    // Find a queue family that supports COMPUTE (sufficient for IPC fabric).
    uint32_t qfam_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(g_dpvk_phys, &qfam_count, NULL);
    VkQueueFamilyProperties* qfams =
        (VkQueueFamilyProperties*)malloc(qfam_count * sizeof(VkQueueFamilyProperties));
    vkGetPhysicalDeviceQueueFamilyProperties(g_dpvk_phys, &qfam_count, qfams);
    for (uint32_t i = 0; i < qfam_count; ++i) {
        if (qfams[i].queueFlags & (VK_QUEUE_COMPUTE_BIT | VK_QUEUE_GRAPHICS_BIT)) {
            g_dpvk_qfam = i;
            break;
        }
    }
    free(qfams);
    if (g_dpvk_qfam == UINT32_MAX) {
        DPLOGE("No suitable queue family");
        vkDestroyInstance(g_dpvk_instance, NULL);
        g_dpvk_instance = VK_NULL_HANDLE;
        return false;
    }

    const float qpri = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        .sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = g_dpvk_qfam,
        .queueCount       = 1,
        .pQueuePriorities = &qpri,
    };

    // Timeline semaphore feature gate.
    VkPhysicalDeviceTimelineSemaphoreFeatures tsf = {
        .sType             = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES,
        .timelineSemaphore = VK_TRUE,
    };
    VkPhysicalDeviceFeatures2 feat2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &tsf,
    };

    const char* dev_exts[] = {
        VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME,
        VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
        VK_KHR_EXTERNAL_SEMAPHORE_EXTENSION_NAME,
        VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
        VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME,
    };
    VkDeviceCreateInfo dci = {
        .sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext                   = &feat2,
        .queueCreateInfoCount    = 1,
        .pQueueCreateInfos       = &qci,
        .enabledExtensionCount   = 5,
        .ppEnabledExtensionNames = dev_exts,
    };
    if (vkCreateDevice(g_dpvk_phys, &dci, NULL, &g_dpvk_device) != VK_SUCCESS) {
        DPLOGE("vkCreateDevice failed");
        vkDestroyInstance(g_dpvk_instance, NULL);
        g_dpvk_instance = VK_NULL_HANDLE;
        return false;
    }

    // Resolve KHR extension PFNs — not guaranteed in static loader on all Android versions.
#define LOAD_PFN(name) \
    pfn_##name = (PFN_##name)vkGetDeviceProcAddr(g_dpvk_device, #name); \
    if (!pfn_##name) { DPLOGE("Failed to load " #name); goto pfn_fail; }

    LOAD_PFN(vkGetMemoryFdKHR)
    LOAD_PFN(vkGetSemaphoreFdKHR)
    LOAD_PFN(vkImportSemaphoreFdKHR)
    LOAD_PFN(vkWaitSemaphoresKHR)
    LOAD_PFN(vkSignalSemaphoreKHR)
    LOAD_PFN(vkGetSemaphoreCounterValueKHR)
#undef LOAD_PFN

    DPLOGI("dp_vk_init OK");
    return true;

pfn_fail:
    vkDestroyDevice(g_dpvk_device, NULL);
    vkDestroyInstance(g_dpvk_instance, NULL);
    g_dpvk_device   = VK_NULL_HANDLE;
    g_dpvk_instance = VK_NULL_HANDLE;
    return false;
}

DP_EXPORT void dp_vk_shutdown(void) {
    if (g_dpvk_device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(g_dpvk_device);
        vkDestroyDevice(g_dpvk_device, NULL);
        g_dpvk_device = VK_NULL_HANDLE;
    }
    if (g_dpvk_instance != VK_NULL_HANDLE) {
        vkDestroyInstance(g_dpvk_instance, NULL);
        g_dpvk_instance = VK_NULL_HANDLE;
    }
    g_dpvk_phys = VK_NULL_HANDLE;
    g_dpvk_qfam = UINT32_MAX;
}

// ─── RESOURCE MANAGEMENT ──────────────────────────────────────────────────────
//
// is_cpu_mappable:
//   true  — HOST_VISIBLE | HOST_COHERENT + LINEAR tiling.  dp_vk_map_memory valid.
//   false — DEVICE_LOCAL + OPTIMAL tiling.  GPU access only via ImageView.
//
// out_image_fd / out_semaphore_fd:
//   Exported opaque Unix fds.  Transmit to consumer via SCM_RIGHTS.
//   Caller owns these fds; close them after the consumer has received them.

DP_EXPORT DP_HANDLE dp_vk_create_shared_resource(uint32_t width, uint32_t height,
                                                  DP_FORMAT format, bool is_cpu_mappable,
                                                  int* out_image_fd, int* out_semaphore_fd) {
    if (!g_dpvk_device) return NULL;
    if (!out_image_fd || !out_semaphore_fd) return NULL;

    VkFormat vkfmt = dp_to_vk_format(format);
    if (vkfmt == VK_FORMAT_UNDEFINED) return NULL;

    DPVk_State* state = (DPVk_State*)calloc(1, sizeof(DPVk_State));
    if (!state) return NULL;
    state->image_fd     = -1;
    state->semaphore_fd = -1;
    state->is_cpu_mappable = is_cpu_mappable;

    // Create VkImage.
    VkMemoryRequirements req = {};
    state->image = create_image(width, height, vkfmt, is_cpu_mappable, &req);
    if (state->image == VK_NULL_HANDLE) goto fail;

    // Allocate and bind exportable device memory.
    // is_cpu_mappable → HOST_VISIBLE | HOST_COHERENT (mirrors D3D12 CUSTOM heap / L0)
    // !is_cpu_mappable → DEVICE_LOCAL               (mirrors D3D12 DEFAULT heap / VRAM)
    {
        VkMemoryPropertyFlags mem_props = is_cpu_mappable
            ? (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)
            : VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
        state->memory = alloc_and_bind(state->image, &req, mem_props);
    }
    if (state->memory == VK_NULL_HANDLE) goto fail;

    // Create timeline semaphore — mirrors ID3D12Fence.
    state->semaphore = create_timeline_semaphore();
    if (state->semaphore == VK_NULL_HANDLE) goto fail;

    // Export image memory fd.
    {
        VkMemoryGetFdInfoKHR gfi = {
            .sType      = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
            .memory     = state->memory,
            .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
        };
        if (pfn_vkGetMemoryFdKHR(g_dpvk_device, &gfi, &state->image_fd) != VK_SUCCESS)
            goto fail;
    }

    // Export semaphore fd.
    {
        VkSemaphoreGetFdInfoKHR gsfi = {
            .sType      = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
            .semaphore  = state->semaphore,
            .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT,
        };
        if (pfn_vkGetSemaphoreFdKHR(g_dpvk_device, &gsfi, &state->semaphore_fd) != VK_SUCCESS)
            goto fail;
    }

    *out_image_fd     = state->image_fd;
    *out_semaphore_fd = state->semaphore_fd;
    return state;

fail:
    if (state->semaphore != VK_NULL_HANDLE) vkDestroySemaphore(g_dpvk_device, state->semaphore, NULL);
    if (state->image_fd  >= 0)              close(state->image_fd);
    if (state->memory    != VK_NULL_HANDLE) vkFreeMemory(g_dpvk_device, state->memory, NULL);
    if (state->image     != VK_NULL_HANDLE) vkDestroyImage(g_dpvk_device, state->image, NULL);
    free(state);
    return NULL;
}

// Consumer side.  image_fd and semaphore_fd are received via SCM_RIGHTS.
// width/height/format/is_cpu_mappable must match the producer's creation params —
// Vulkan opaque fds carry no metadata, unlike NT kernel objects.
DP_EXPORT DP_HANDLE dp_vk_open_shared_resource(uint32_t width, uint32_t height,
                                                DP_FORMAT format, bool is_cpu_mappable,
                                                int image_fd, int semaphore_fd) {
    if (!g_dpvk_device) return NULL;

    VkFormat vkfmt = dp_to_vk_format(format);
    if (vkfmt == VK_FORMAT_UNDEFINED) return NULL;

    DPVk_State* state = (DPVk_State*)calloc(1, sizeof(DPVk_State));
    if (!state) return NULL;
    state->image_fd        = -1;   // consumer does not hold an exportable fd
    state->semaphore_fd    = -1;
    state->is_cpu_mappable = is_cpu_mappable;

    // Create a matching VkImage to bind the imported memory to.
    VkMemoryRequirements req = {};
    state->image = create_image(width, height, vkfmt, is_cpu_mappable, &req);
    if (state->image == VK_NULL_HANDLE) goto fail;

    // Import memory from fd.
    {
        VkImportMemoryFdInfoKHR import_info = {
            .sType      = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
            .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
            .fd         = image_fd,
        };
        uint32_t mtype = find_memory_type(
            is_cpu_mappable
                ? (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)
                : VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            req.memoryTypeBits);
        if (mtype == UINT32_MAX) goto fail;

        VkMemoryAllocateInfo ai = {
            .sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext           = &import_info,
            .allocationSize  = req.size,
            .memoryTypeIndex = mtype,
        };
        if (vkAllocateMemory(g_dpvk_device, &ai, NULL, &state->memory) != VK_SUCCESS) goto fail;
        if (vkBindImageMemory(g_dpvk_device, state->image, state->memory, 0) != VK_SUCCESS) goto fail;
    }

    // Create timeline semaphore shell, then import fd into it.
    {
        VkSemaphoreTypeCreateInfo type_info = {
            .sType         = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
            .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
            .initialValue  = 0,
        };
        VkSemaphoreCreateInfo sci = {
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = &type_info,
        };
        if (vkCreateSemaphore(g_dpvk_device, &sci, NULL, &state->semaphore) != VK_SUCCESS)
            goto fail;

        VkImportSemaphoreFdInfoKHR isfi = {
            .sType      = VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR,
            .semaphore  = state->semaphore,
            .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT,
            .fd         = semaphore_fd,
        };
        if (pfn_vkImportSemaphoreFdKHR(g_dpvk_device, &isfi) != VK_SUCCESS) goto fail;
    }

    return state;

fail:
    if (state->semaphore != VK_NULL_HANDLE) vkDestroySemaphore(g_dpvk_device, state->semaphore, NULL);
    if (state->memory    != VK_NULL_HANDLE) vkFreeMemory(g_dpvk_device, state->memory, NULL);
    if (state->image     != VK_NULL_HANDLE) vkDestroyImage(g_dpvk_device, state->image, NULL);
    free(state);
    return NULL;
}

// ─── CPU MEMORY ACCESS ────────────────────────────────────────────────────────
//
// Valid ONLY when is_cpu_mappable=true (HOST_VISIBLE + LINEAR tiling).
// GPU-only resources (DEVICE_LOCAL / OPTIMAL tiling): vkMapMemory will fail.
//
// row_pitch is sourced from vkGetImageSubresourceLayout — the driver-authoritative
// value. This replaces the manual (Width * bpp + 255) & ~255 calculation in the
// D3D12 version, which truncated silently on very wide allocations and was
// advisory rather than authoritative.

DP_EXPORT void* dp_vk_map_memory(DP_HANDLE handle, uint32_t* out_row_pitch) {
    DPVk_State* state = (DPVk_State*)handle;
    if (!state || !state->is_cpu_mappable) return NULL;

    // Cache layout on first call; it is immutable after image creation.
    if (state->row_pitch == 0) {
        VkImageSubresource  sub    = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0 };
        VkSubresourceLayout layout = {};
        vkGetImageSubresourceLayout(g_dpvk_device, state->image, &sub, &layout);
        state->row_pitch = layout.rowPitch;
    }

    void* ptr = NULL;
    // vkMapMemory maps the full allocation. offset=0, size=VK_WHOLE_SIZE.
    VkResult r = vkMapMemory(g_dpvk_device, state->memory, 0, VK_WHOLE_SIZE, 0, &ptr);
    if (r != VK_SUCCESS) {
        DPLOGE("vkMapMemory failed: %d", r);
        return NULL;   // Caller must check for NULL — unlike the D3D12 original.
    }

    if (out_row_pitch)
        *out_row_pitch = (uint32_t)state->row_pitch;

    return ptr;
}

DP_EXPORT void dp_vk_unmap_memory(DP_HANDLE handle) {
    DPVk_State* state = (DPVk_State*)handle;
    if (state) vkUnmapMemory(g_dpvk_device, state->memory);
}

// ─── FENCE / SEMAPHORE OPERATIONS ────────────────────────────────────────────
//
// dp_vk_signal_fence  — CPU signals the timeline semaphore to frame_value.
//                       Mirrors ID3D12Fence::Signal.
//
// dp_vk_cpu_wait      — CPU blocks until semaphore reaches target_value.
//                       Mirrors dp12_cpu_wait / WaitForSingleObject path.
//                       No separate event object required — vkWaitSemaphoresKHR
//                       is the native blocking primitive.
//
// dp_vk_queue_wait    — GPU command queue stalls at hardware level until
//                       semaphore reaches target_value.  CPU returns immediately.
//                       Mirrors pQueue->Wait(fence, value).
//                       Implemented as an empty vkQueueSubmit with a timeline
//                       wait semaphore; subsequent submissions on the same queue
//                       will not execute until the condition is met.

DP_EXPORT void dp_vk_signal_fence(DP_HANDLE handle, uint64_t frame_value) {
    DPVk_State* state = (DPVk_State*)handle;
    VkSemaphoreSignalInfo si = {
        .sType     = VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO,
        .semaphore = state->semaphore,
        .value     = frame_value,
    };
    pfn_vkSignalSemaphoreKHR(g_dpvk_device, &si);
}

DP_EXPORT void dp_vk_cpu_wait(DP_HANDLE handle, uint64_t target_value) {
    DPVk_State* state = (DPVk_State*)handle;
    VkSemaphoreWaitInfo wi = {
        .sType          = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
        .semaphoreCount = 1,
        .pSemaphores    = &state->semaphore,
        .pValues        = &target_value,
    };
    // Blocks the calling CPU thread.  No OS event object needed — the KHR
    // extension provides the blocking primitive directly, replacing
    // SetEventOnCompletion + WaitForSingleObject from the D3D12 version.
    pfn_vkWaitSemaphoresKHR(g_dpvk_device, &wi, UINT64_MAX);
}

DP_EXPORT void dp_vk_queue_wait(DP_HANDLE handle, VkQueue queue, uint64_t target_value) {
    DPVk_State* state = (DPVk_State*)handle;

    // GPU hardware stall: submit empty batch with timeline wait.
    // The queue will not advance past this submission until the semaphore
    // reaches target_value.  CPU thread returns immediately.
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkTimelineSemaphoreSubmitInfo tssi = {
        .sType                     = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
        .waitSemaphoreValueCount   = 1,
        .pWaitSemaphoreValues      = &target_value,
        .signalSemaphoreValueCount = 0,
    };
    VkSubmitInfo si = {
        .sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext                = &tssi,
        .waitSemaphoreCount   = 1,
        .pWaitSemaphores      = &state->semaphore,
        .pWaitDstStageMask    = &stage,
        .commandBufferCount   = 0,
        .signalSemaphoreCount = 0,
    };
    vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE);
}

DP_EXPORT uint64_t dp_vk_get_completed_value(DP_HANDLE handle) {
    DPVk_State* state = (DPVk_State*)handle;
    uint64_t val = 0;
    pfn_vkGetSemaphoreCounterValueKHR(g_dpvk_device, state->semaphore, &val);
    return val;
}

// ─── HANDLE ACCESSORS ─────────────────────────────────────────────────────────
// Return the exported fds for the caller to transmit cross-process (SCM_RIGHTS).
// These are valid only on the producer side (create path); -1 on consumer side.

DP_EXPORT int dp_vk_get_image_fd(DP_HANDLE handle) {
    return ((DPVk_State*)handle)->image_fd;
}

DP_EXPORT int dp_vk_get_semaphore_fd(DP_HANDLE handle) {
    return ((DPVk_State*)handle)->semaphore_fd;
}

// ─── CLEANUP ──────────────────────────────────────────────────────────────────
// Mirrors dp12_close.
// Note on fds: the opaque memory fd is consumed (ownership transferred to the
// VkDeviceMemory allocation) when vkAllocateMemory / vkImportSemaphoreFdKHR
// succeed — Vulkan closes it internally.  Only fds that were NOT consumed
// (i.e., never passed to an import call) need explicit close() here.
// For the producer path, image_fd and semaphore_fd are exported fds that the
// caller may have already closed after transmitting; guard with fd >= 0.

DP_EXPORT void dp_vk_close(DP_HANDLE handle) {
    DPVk_State* state = (DPVk_State*)handle;
    if (!state) return;

    // Exported fds on producer side — close if still open.
    // (Equivalent to FIX 1 in D3D12 version: CloseHandle(hSharedTex/hSharedFence).
    //  Without this, the fd reference keeping the Vulkan object name alive leaks.)
    if (state->semaphore_fd >= 0) { close(state->semaphore_fd); state->semaphore_fd = -1; }
    if (state->image_fd     >= 0) { close(state->image_fd);     state->image_fd     = -1; }

    if (state->semaphore != VK_NULL_HANDLE)
        vkDestroySemaphore(g_dpvk_device, state->semaphore, NULL);
    if (state->memory != VK_NULL_HANDLE)
        vkFreeMemory(g_dpvk_device, state->memory, NULL);
    if (state->image != VK_NULL_HANDLE)
        vkDestroyImage(g_dpvk_device, state->image, NULL);

    // Device lifecycle is global. Do not destroy g_dpvk_device here.

    free(state);
}
