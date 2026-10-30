// See vkrender.h.

#define VK_USE_PLATFORM_ANDROID_KHR
#include "vkrender.h"

#include <android/log.h>
#include <math.h>
#include <string.h>

#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vulkan.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>

#include "shaders/video_frag_spv.h"
#include "shaders/video_vert_spv.h"

#define TAG "ProViewGPU"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#define SLOTS 2         // frames in flight
#define MAX_IMAGES 8    // swapchain images
#define MAX_PLANES 3

#define VK_FUNCS(X)                                  \
    X(GetDeviceProcAddr)                             \
    X(GetPhysicalDeviceFormatProperties)             \
    X(GetPhysicalDeviceSurfaceCapabilitiesKHR)       \
    X(GetPhysicalDeviceSurfaceFormatsKHR)            \
    X(GetPhysicalDeviceSurfaceSupportKHR)            \
    X(CreateAndroidSurfaceKHR)                       \
    X(DestroySurfaceKHR)

#define VK_DEV_FUNCS(X)                              \
    X(GetDeviceQueue)                                \
    X(CreateSwapchainKHR)                            \
    X(DestroySwapchainKHR)                           \
    X(GetSwapchainImagesKHR)                         \
    X(AcquireNextImageKHR)                           \
    X(QueuePresentKHR)                               \
    X(CreateImageView)                               \
    X(DestroyImageView)                              \
    X(CreateSampler)                                 \
    X(DestroySampler)                                \
    X(CreateDescriptorSetLayout)                     \
    X(DestroyDescriptorSetLayout)                    \
    X(CreatePipelineLayout)                          \
    X(DestroyPipelineLayout)                         \
    X(CreateShaderModule)                            \
    X(DestroyShaderModule)                           \
    X(CreateGraphicsPipelines)                       \
    X(DestroyPipeline)                               \
    X(CreateDescriptorPool)                          \
    X(DestroyDescriptorPool)                         \
    X(AllocateDescriptorSets)                        \
    X(UpdateDescriptorSets)                          \
    X(CreateCommandPool)                             \
    X(DestroyCommandPool)                            \
    X(AllocateCommandBuffers)                        \
    X(BeginCommandBuffer)                            \
    X(EndCommandBuffer)                              \
    X(ResetCommandBuffer)                            \
    X(CmdPipelineBarrier2)                           \
    X(CmdBeginRendering)                             \
    X(CmdEndRendering)                               \
    X(CmdBindPipeline)                               \
    X(CmdBindDescriptorSets)                         \
    X(CmdPushConstants)                              \
    X(CmdDraw)                                       \
    X(CmdSetViewport)                                \
    X(CmdSetScissor)                                 \
    X(CreateFence)                                   \
    X(DestroyFence)                                  \
    X(WaitForFences)                                 \
    X(ResetFences)                                   \
    X(CreateSemaphore)                               \
    X(DestroySemaphore)                              \
    X(QueueWaitIdle)                                 \
    X(QueueSubmit2)

typedef struct PushConstants {
    float dst[4];
    float uvx[4];
    float uvy[4];
    float m0[4], m1[4], m2[4];
    float scale[4];
    int32_t mode;
} PushConstants;

typedef struct Slot {
    VkCommandBuffer cmd;
    VkFence fence;
    VkSemaphore acquired;
    VkDescriptorSet set;
    VkImageView views[MAX_PLANES];
    AVFrame *hold;   // keeps the frame's images alive until the GPU is done with them
    int busy;
} Slot;

struct VkRender {
    AVBufferRef *dev_ref;
    AVHWDeviceContext *dev;
    AVVulkanDeviceContext *hw;
    VkInstance inst;
    VkPhysicalDevice phys;
    VkDevice device;
#define DECL(name) PFN_vk##name name;
    VK_FUNCS(DECL)
    VK_DEV_FUNCS(DECL)
#undef DECL

    int qf;            // graphics queue family
    VkQueue queue;
    VkCommandPool pool;
    VkDescriptorPool dpool;
    VkDescriptorSetLayout dsl;
    VkPipelineLayout layout;
    VkSampler sampler;
    VkShaderModule vert, frag;
    VkPipeline pipeline;
    VkFormat pipeline_format;
    Slot slots[SLOTS];
    int slot;

    // Window
    ANativeWindow *window;
    int win_w, win_h;
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkFormat format;
    VkExtent2D extent;
    uint32_t nb_images;
    VkImage images[MAX_IMAGES];
    VkImageView image_views[MAX_IMAGES];
    VkSemaphore rendered[MAX_IMAGES];
    int dirty;
    int out_bits;

    // Uploads of software frames
    AVBufferRef *upload_fc;
    enum AVPixelFormat upload_fmt;
    int upload_w, upload_h;
    SwsContext *sws;     // converts formats the GPU path can't sample directly
    AVFrame *converted;

    AVFrame *last;       // most recently drawn frame, for redraws
    uint32_t frame_no;
    int ready;           // all function pointers loaded
};

static void queue_lock(VkRender *r) {
#if FF_API_VULKAN_SYNC_QUEUES
    if (r->hw->lock_queue) r->hw->lock_queue(r->dev, r->qf, 0);
#endif
}

static void queue_unlock(VkRender *r) {
#if FF_API_VULKAN_SYNC_QUEUES
    if (r->hw->unlock_queue) r->hw->unlock_queue(r->dev, r->qf, 0);
#endif
}

// ---------------------------------------------------------------------------
// Setup

static int create_pipeline_objects(VkRender *r) {
    VkFormatProperties fp;
    r->GetPhysicalDeviceFormatProperties(r->phys, VK_FORMAT_R16_UNORM, &fp);
    int linear = !!(fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT);
    VkSamplerCreateInfo si = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = linear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST,
        .minFilter = linear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST,
        .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .maxLod = 0,
    };
    if (r->CreateSampler(r->device, &si, NULL, &r->sampler) != VK_SUCCESS) return -1;

    VkSampler samplers[MAX_PLANES] = {r->sampler, r->sampler, r->sampler};
    VkDescriptorSetLayoutBinding b[MAX_PLANES];
    for (int i = 0; i < MAX_PLANES; i++) {
        b[i] = (VkDescriptorSetLayoutBinding) {
            .binding = i,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = &samplers[i],
        };
    }
    VkDescriptorSetLayoutCreateInfo dli = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = MAX_PLANES,
        .pBindings = b,
    };
    if (r->CreateDescriptorSetLayout(r->device, &dli, NULL, &r->dsl) != VK_SUCCESS) return -1;

    VkPushConstantRange pcr = {
        .stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
        .size = sizeof(PushConstants),
    };
    VkPipelineLayoutCreateInfo pli = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &r->dsl,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &pcr,
    };
    if (r->CreatePipelineLayout(r->device, &pli, NULL, &r->layout) != VK_SUCCESS) return -1;

    VkShaderModuleCreateInfo vs = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = sizeof(video_vert_spv),
        .pCode = video_vert_spv,
    };
    VkShaderModuleCreateInfo fs = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = sizeof(video_frag_spv),
        .pCode = video_frag_spv,
    };
    if (r->CreateShaderModule(r->device, &vs, NULL, &r->vert) != VK_SUCCESS ||
        r->CreateShaderModule(r->device, &fs, NULL, &r->frag) != VK_SUCCESS)
        return -1;

    VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, SLOTS * MAX_PLANES};
    VkDescriptorPoolCreateInfo dpi = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = SLOTS,
        .poolSizeCount = 1,
        .pPoolSizes = &ps,
    };
    if (r->CreateDescriptorPool(r->device, &dpi, NULL, &r->dpool) != VK_SUCCESS) return -1;

    VkCommandPoolCreateInfo cpi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = r->qf,
    };
    if (r->CreateCommandPool(r->device, &cpi, NULL, &r->pool) != VK_SUCCESS) return -1;

    for (int i = 0; i < SLOTS; i++) {
        Slot *s = &r->slots[i];
        VkCommandBufferAllocateInfo ai = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = r->pool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        VkFenceCreateInfo fi = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        VkSemaphoreCreateInfo sci = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        VkDescriptorSetAllocateInfo dai = {
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = r->dpool,
            .descriptorSetCount = 1,
            .pSetLayouts = &r->dsl,
        };
        if (r->AllocateCommandBuffers(r->device, &ai, &s->cmd) != VK_SUCCESS ||
            r->CreateFence(r->device, &fi, NULL, &s->fence) != VK_SUCCESS ||
            r->CreateSemaphore(r->device, &sci, NULL, &s->acquired) != VK_SUCCESS ||
            r->AllocateDescriptorSets(r->device, &dai, &s->set) != VK_SUCCESS)
            return -1;
    }
    return 0;
}

static int create_pipeline(VkRender *r, VkFormat format) {
    if (r->pipeline && r->pipeline_format == format) return 0;
    if (r->pipeline) r->DestroyPipeline(r->device, r->pipeline, NULL);
    r->pipeline = VK_NULL_HANDLE;

    VkPipelineShaderStageCreateInfo stages[2] = {
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = r->vert, .pName = "main"},
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = r->frag, .pName = "main"},
    };
    VkPipelineVertexInputStateCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo ia = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
    };
    VkPipelineViewportStateCreateInfo vp = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };
    VkPipelineRasterizationStateCreateInfo rs = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL,
        .cullMode = VK_CULL_MODE_NONE,
        .lineWidth = 1.0f,
    };
    VkPipelineMultisampleStateCreateInfo ms = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
    };
    VkPipelineColorBlendAttachmentState cba = {.colorWriteMask = 0xF};
    VkPipelineColorBlendStateCreateInfo cb = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &cba,
    };
    VkDynamicState dyn[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo ds = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = 2,
        .pDynamicStates = dyn,
    };
    VkPipelineRenderingCreateInfo ri = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &format,
    };
    VkGraphicsPipelineCreateInfo gi = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &ri,
        .stageCount = 2,
        .pStages = stages,
        .pVertexInputState = &vi,
        .pInputAssemblyState = &ia,
        .pViewportState = &vp,
        .pRasterizationState = &rs,
        .pMultisampleState = &ms,
        .pColorBlendState = &cb,
        .pDynamicState = &ds,
        .layout = r->layout,
    };
    if (r->CreateGraphicsPipelines(r->device, VK_NULL_HANDLE, 1, &gi, NULL, &r->pipeline) != VK_SUCCESS) {
        r->pipeline = VK_NULL_HANDLE;
        return -1;
    }
    r->pipeline_format = format;
    return 0;
}

VkRender *vkr_create(void) {
    VkRender *r = av_mallocz(sizeof(*r));
    if (!r) return NULL;
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "instance_extensions", "VK_KHR_surface+VK_KHR_android_surface", 0);
    av_dict_set(&opts, "device_extensions", "VK_KHR_swapchain", 0);
    // One VkImage per plane, so every plane can be sampled with a plain R16/R8 view.
    av_dict_set(&opts, "disable_multiplane", "1", 0);
    int ret = av_hwdevice_ctx_create(&r->dev_ref, AV_HWDEVICE_TYPE_VULKAN, NULL, opts, 0);
    av_dict_free(&opts);
    if (ret < 0) {
        LOGI("Vulkan unavailable (%s); using the CPU display path", av_err2str(ret));
        av_free(r);
        return NULL;
    }
    r->dev = (AVHWDeviceContext *) r->dev_ref->data;
    r->hw = r->dev->hwctx;
    r->inst = r->hw->inst;
    r->phys = r->hw->phys_dev;
    r->device = r->hw->act_dev;

    int have_swapchain = 0, have_surface = 0;
    for (int i = 0; i < r->hw->nb_enabled_dev_extensions; i++)
        if (!strcmp(r->hw->enabled_dev_extensions[i], VK_KHR_SWAPCHAIN_EXTENSION_NAME)) have_swapchain = 1;
    for (int i = 0; i < r->hw->nb_enabled_inst_extensions; i++)
        if (!strcmp(r->hw->enabled_inst_extensions[i], VK_KHR_ANDROID_SURFACE_EXTENSION_NAME)) have_surface = 1;
    if (!have_swapchain || !have_surface) {
        LOGI("Vulkan has no swapchain support; using the CPU display path");
        vkr_destroy(r);
        return NULL;
    }

    PFN_vkGetInstanceProcAddr gipa = r->hw->get_proc_addr;
#define LOAD(name)                                                                  \
    if (!(r->name = (PFN_vk##name) gipa(r->inst, "vk" #name))) {                    \
        LOGE("missing vk" #name);                                                   \
        vkr_destroy(r);                                                             \
        return NULL;                                                                \
    }
    VK_FUNCS(LOAD)
#undef LOAD
#define LOAD(name)                                                                  \
    if (!(r->name = (PFN_vk##name) r->GetDeviceProcAddr(r->device, "vk" #name))) {  \
        LOGE("missing vk" #name);                                                   \
        vkr_destroy(r);                                                             \
        return NULL;                                                                \
    }
    VK_DEV_FUNCS(LOAD)
#undef LOAD

    // Draw on the first graphics queue family FFmpeg enabled.
    r->qf = -1;
    for (int i = 0; i < r->hw->nb_qf; i++) {
        if (r->hw->qf[i].flags & VK_QUEUE_GRAPHICS_BIT) {
            r->qf = r->hw->qf[i].idx;
            break;
        }
    }
    if (r->qf < 0) {
        LOGI("Vulkan device has no graphics queue; using the CPU display path");
        vkr_destroy(r);
        return NULL;
    }
    r->GetDeviceQueue(r->device, r->qf, 0, &r->queue);
    r->ready = 1;
    if (create_pipeline_objects(r) < 0) {
        LOGE("couldn't create Vulkan render objects");
        vkr_destroy(r);
        return NULL;
    }
    LOGI("Vulkan video output ready (queue family %d)", r->qf);
    return r;
}

AVBufferRef *vkr_device(VkRender *r) { return r->dev_ref; }

int vkr_output_bits(VkRender *r) { return r->swapchain ? r->out_bits : 0; }

// ---------------------------------------------------------------------------
// Swapchain

static void wait_slots(VkRender *r) {
    for (int i = 0; i < SLOTS; i++) {
        Slot *s = &r->slots[i];
        if (s->busy) {
            r->WaitForFences(r->device, 1, &s->fence, VK_TRUE, UINT64_MAX);
            r->ResetFences(r->device, 1, &s->fence);
            s->busy = 0;
        }
        for (int p = 0; p < MAX_PLANES; p++) {
            if (s->views[p]) r->DestroyImageView(r->device, s->views[p], NULL);
            s->views[p] = VK_NULL_HANDLE;
        }
        av_frame_free(&s->hold);
    }
}

static void destroy_swapchain_images(VkRender *r) {
    for (uint32_t i = 0; i < r->nb_images; i++) {
        if (r->image_views[i]) r->DestroyImageView(r->device, r->image_views[i], NULL);
        if (r->rendered[i]) r->DestroySemaphore(r->device, r->rendered[i], NULL);
        r->image_views[i] = VK_NULL_HANDLE;
        r->rendered[i] = VK_NULL_HANDLE;
    }
    r->nb_images = 0;
}

static void destroy_surface(VkRender *r) {
    wait_slots(r);
    // Presentation may still reference the swapchain; idle our queue before tearing it down.
    queue_lock(r);
    r->QueueWaitIdle(r->queue);
    queue_unlock(r);
    destroy_swapchain_images(r);
    if (r->swapchain) r->DestroySwapchainKHR(r->device, r->swapchain, NULL);
    if (r->surface) r->DestroySurfaceKHR(r->inst, r->surface, NULL);
    r->swapchain = VK_NULL_HANDLE;
    r->surface = VK_NULL_HANDLE;
}

static VkSurfaceFormatKHR pick_format(VkRender *r) {
    uint32_t n = 0;
    r->GetPhysicalDeviceSurfaceFormatsKHR(r->phys, r->surface, &n, NULL);
    VkSurfaceFormatKHR formats[64];
    if (n > 64) n = 64;
    r->GetPhysicalDeviceSurfaceFormatsKHR(r->phys, r->surface, &n, formats);
    // 10-bit first: the whole point is showing 10-bit video without banding.
    static const VkFormat prefs[] = {
        VK_FORMAT_A2B10G10R10_UNORM_PACK32,
        VK_FORMAT_A2R10G10B10_UNORM_PACK32,
        VK_FORMAT_R8G8B8A8_UNORM,
        VK_FORMAT_B8G8R8A8_UNORM,
    };
    for (size_t p = 0; p < sizeof(prefs) / sizeof(prefs[0]); p++)
        for (uint32_t i = 0; i < n; i++)
            if (formats[i].format == prefs[p] && formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
                return formats[i];
    return formats[0];
}

static int create_swapchain(VkRender *r) {
    if (!r->window) return -1;
    if (!r->surface) {
        VkAndroidSurfaceCreateInfoKHR ci = {
            .sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR,
            .window = r->window,
        };
        if (r->CreateAndroidSurfaceKHR(r->inst, &ci, NULL, &r->surface) != VK_SUCCESS) {
            LOGE("vkCreateAndroidSurfaceKHR failed");
            return -1;
        }
        VkBool32 ok = VK_FALSE;
        r->GetPhysicalDeviceSurfaceSupportKHR(r->phys, r->qf, r->surface, &ok);
        if (!ok) {
            LOGE("queue family %d can't present", r->qf);
            return -1;
        }
    }
    VkSurfaceCapabilitiesKHR caps;
    if (r->GetPhysicalDeviceSurfaceCapabilitiesKHR(r->phys, r->surface, &caps) != VK_SUCCESS) return -1;
    VkExtent2D extent = caps.currentExtent;
    if (extent.width == 0xFFFFFFFF || extent.width == 0) {
        extent.width = r->win_w > 0 ? r->win_w : ANativeWindow_getWidth(r->window);
        extent.height = r->win_h > 0 ? r->win_h : ANativeWindow_getHeight(r->window);
    }
    if (extent.width == 0 || extent.height == 0) return -1;

    VkSurfaceFormatKHR sf = pick_format(r);
    uint32_t count = caps.minImageCount < 3 ? 3 : caps.minImageCount;
    if (caps.maxImageCount && count > caps.maxImageCount) count = caps.maxImageCount;
    if (count > MAX_IMAGES) count = MAX_IMAGES;
    VkCompositeAlphaFlagBitsKHR alpha = VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    if (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR) alpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    else if (!(caps.supportedCompositeAlpha & alpha)) alpha = VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;

    VkSwapchainKHR old = r->swapchain;
    VkSwapchainCreateInfoKHR ci = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = r->surface,
        .minImageCount = count,
        .imageFormat = sf.format,
        .imageColorSpace = sf.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = (caps.supportedTransforms & VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR)
                            ? VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR : caps.currentTransform,
        .compositeAlpha = alpha,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE,
        .oldSwapchain = old,
    };
    wait_slots(r);
    destroy_swapchain_images(r);
    VkSwapchainKHR sc;
    VkResult res = r->CreateSwapchainKHR(r->device, &ci, NULL, &sc);
    if (old) r->DestroySwapchainKHR(r->device, old, NULL);
    r->swapchain = VK_NULL_HANDLE;
    if (res != VK_SUCCESS) {
        LOGE("vkCreateSwapchainKHR failed (%d)", res);
        return -1;
    }
    r->swapchain = sc;
    r->format = sf.format;
    r->extent = extent;
    r->out_bits = (sf.format == VK_FORMAT_A2B10G10R10_UNORM_PACK32 ||
                   sf.format == VK_FORMAT_A2R10G10B10_UNORM_PACK32) ? 10 : 8;

    r->nb_images = MAX_IMAGES;
    r->GetSwapchainImagesKHR(r->device, sc, &r->nb_images, r->images);
    for (uint32_t i = 0; i < r->nb_images; i++) {
        VkImageViewCreateInfo vi = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = r->images[i],
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = sf.format,
            .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
        };
        VkSemaphoreCreateInfo sci = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        if (r->CreateImageView(r->device, &vi, NULL, &r->image_views[i]) != VK_SUCCESS ||
            r->CreateSemaphore(r->device, &sci, NULL, &r->rendered[i]) != VK_SUCCESS)
            return -1;
    }
    if (create_pipeline(r, sf.format) < 0) return -1;
    r->dirty = 0;
    LOGI("swapchain %ux%u, %d-bit, %u images", extent.width, extent.height, r->out_bits, r->nb_images);
    return 0;
}

void vkr_set_window(VkRender *r, ANativeWindow *win, int width, int height) {
    // The view moving or resizing (rotation, layout) doesn't change a fixed-size surface: keep the swapchain.
    if (win == r->window && width == r->win_w && height == r->win_h && r->swapchain) return;
    if (win != r->window) {
        destroy_surface(r);
        if (r->window) ANativeWindow_release(r->window);
        r->window = win;
        if (win) ANativeWindow_acquire(win);
    }
    r->win_w = width;
    r->win_h = height;
    r->dirty = 1;
}

// ---------------------------------------------------------------------------
// Drawing

// Fills in the YCbCr -> RGB matrix (with range expansion) for normalised sample values.
static void color_matrix(const AVFrame *f, int depth, PushConstants *pc) {
    double kr = 0.2126, kb = 0.0722;   // BT.709
    enum AVColorSpace cs = f->colorspace;
    if (cs == AVCOL_SPC_UNSPECIFIED) cs = f->height >= 720 ? AVCOL_SPC_BT709 : AVCOL_SPC_SMPTE170M;
    if (cs == AVCOL_SPC_SMPTE170M || cs == AVCOL_SPC_BT470BG) kr = 0.299, kb = 0.114;
    else if (cs == AVCOL_SPC_BT2020_NCL || cs == AVCOL_SPC_BT2020_CL) kr = 0.2627, kb = 0.0593;
    double kg = 1.0 - kr - kb;

    double max = (1 << depth) - 1, unit = 1 << (depth - 8);
    double ay, by, ac, bc;
    if (f->color_range == AVCOL_RANGE_JPEG) {
        ay = 1.0, by = 0.0;
        ac = 1.0, bc = -(double) (1 << (depth - 1)) / max;
    } else {
        ay = max / (219.0 * unit), by = -16.0 / 219.0;
        ac = max / (224.0 * unit), bc = -128.0 / 224.0;
    }
    // RGB = M * (Y, Cb, Cr) with Y = ay*y + by and C = ac*c + bc.
    double m[3][3] = {
        {1.0, 0.0, 2.0 * (1.0 - kr)},
        {1.0, -2.0 * kb * (1.0 - kb) / kg, -2.0 * kr * (1.0 - kr) / kg},
        {1.0, 2.0 * (1.0 - kb), 0.0},
    };
    float *rows[3] = {pc->m0, pc->m1, pc->m2};
    for (int i = 0; i < 3; i++) {
        rows[i][0] = (float) (m[i][0] * ay);
        rows[i][1] = (float) (m[i][1] * ac);
        rows[i][2] = (float) (m[i][2] * ac);
        rows[i][3] = (float) (m[i][0] * by + (m[i][1] + m[i][2]) * bc);
    }
}

// Whether the shader can sample this layout directly: 8-16 bit YCbCr, planar or Y + interleaved CbCr.
static int sampleable(enum AVPixelFormat fmt) {
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(fmt);
    if (!d || d->nb_components < 3 || (d->flags & (AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_PAL |
                                                    AV_PIX_FMT_FLAG_BE | AV_PIX_FMT_FLAG_BITSTREAM |
                                                    AV_PIX_FMT_FLAG_FLOAT | AV_PIX_FMT_FLAG_BAYER)))
        return 0;
    if (!(d->flags & AV_PIX_FMT_FLAG_PLANAR)) return 0;
    if (d->comp[0].plane != 0 || d->comp[1].plane != 1) return 0;
    if (d->comp[0].depth + d->comp[0].shift > 16 || d->comp[0].depth < 8) return 0;
    return 1;
}

// Uploads a software frame into a Vulkan frame (converting the layout first if needed).
static AVFrame *upload(VkRender *r, const AVFrame *src) {
    const AVFrame *in = src;
    if (!sampleable(src->format)) {
        const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(src->format);
        enum AVPixelFormat target = d && d->comp[0].depth > 8 ? AV_PIX_FMT_YUV444P16 : AV_PIX_FMT_YUV444P;
        if (!r->converted) r->converted = av_frame_alloc();
        av_frame_unref(r->converted);
        r->converted->format = target;
        r->converted->width = src->width;
        r->converted->height = src->height;
        r->converted->color_range = AVCOL_RANGE_JPEG;
        r->converted->colorspace = AVCOL_SPC_BT709;
        if (!r->sws) r->sws = sws_alloc_context();
        if (sws_scale_frame(r->sws, r->converted, src) < 0) return NULL;
        in = r->converted;
    }
    if (!r->upload_fc || r->upload_fmt != in->format || r->upload_w != in->width || r->upload_h != in->height) {
        av_buffer_unref(&r->upload_fc);
        AVBufferRef *fc_ref = av_hwframe_ctx_alloc(r->dev_ref);
        if (!fc_ref) return NULL;
        AVHWFramesContext *fc = (AVHWFramesContext *) fc_ref->data;
        fc->format = AV_PIX_FMT_VULKAN;
        fc->sw_format = in->format;
        fc->width = in->width;
        fc->height = in->height;
        if (av_hwframe_ctx_init(fc_ref) < 0) {
            LOGE("Vulkan can't hold %s frames", av_get_pix_fmt_name(in->format));
            av_buffer_unref(&fc_ref);
            return NULL;
        }
        r->upload_fc = fc_ref;
        r->upload_fmt = in->format;
        r->upload_w = in->width;
        r->upload_h = in->height;
    }
    AVFrame *out = av_frame_alloc();
    if (!out || av_hwframe_get_buffer(r->upload_fc, out, 0) < 0 || av_hwframe_transfer_data(out, in, 0) < 0) {
        av_frame_free(&out);
        return NULL;
    }
    av_frame_copy_props(out, in);
    if (in == r->converted) {
        out->color_range = AVCOL_RANGE_JPEG;
        out->colorspace = AVCOL_SPC_BT709;
    }
    out->width = in->width;
    out->height = in->height;
    return out;
}

static VkFormat plane_format(int bits16, int comps) {
    if (comps == 2) return bits16 ? VK_FORMAT_R16G16_UNORM : VK_FORMAT_R8G8_UNORM;
    return bits16 ? VK_FORMAT_R16_UNORM : VK_FORMAT_R8_UNORM;
}

static int render(VkRender *r, AVFrame *frame, const VkrView *view) {
    if (r->dirty || !r->swapchain) {
        if (create_swapchain(r) < 0) return AVERROR_EXTERNAL;
    }
    AVHWFramesContext *fc = (AVHWFramesContext *) frame->hw_frames_ctx->data;
    AVVulkanFramesContext *vkfc = fc->hwctx;
    AVVkFrame *vkf = (AVVkFrame *) frame->data[0];
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(fc->sw_format);
    int planes = av_pix_fmt_count_planes(fc->sw_format);
    if (planes > MAX_PLANES) planes = MAX_PLANES;   // alpha is ignored
    int nb_img = 0;
    while (nb_img < AV_NUM_DATA_POINTERS && vkf->img[nb_img]) nb_img++;
    int semi = d->comp[1].plane == d->comp[2].plane;
    int depth = d->comp[0].depth;
    int bits16 = depth + d->comp[0].shift > 8;

    Slot *s = &r->slots[r->slot];
    if (s->busy) {
        r->WaitForFences(r->device, 1, &s->fence, VK_TRUE, UINT64_MAX);
        r->ResetFences(r->device, 1, &s->fence);
        s->busy = 0;
    }
    for (int p = 0; p < MAX_PLANES; p++) {
        if (s->views[p]) r->DestroyImageView(r->device, s->views[p], NULL);
        s->views[p] = VK_NULL_HANDLE;
    }
    av_frame_free(&s->hold);

    uint32_t idx;
    VkResult res = r->AcquireNextImageKHR(r->device, r->swapchain, 1000000000ULL, s->acquired, VK_NULL_HANDLE, &idx);
    if (res == VK_ERROR_OUT_OF_DATE_KHR) {
        r->dirty = 1;
        return AVERROR(EAGAIN);
    }
    if (res != VK_SUCCESS && res != VK_SUBOPTIMAL_KHR) return AVERROR_EXTERNAL;
    if (res == VK_SUBOPTIMAL_KHR) r->dirty = 1;

    // Views for each plane (one image per plane, or plane aspects of a single multi-planar image).
    VkDescriptorImageInfo infos[MAX_PLANES];
    for (int p = 0; p < MAX_PLANES; p++) {
        int pp = p < planes ? p : planes - 1;
        int comps = 0;
        for (int c = 0; c < d->nb_components; c++)
            if (d->comp[c].plane == pp) comps++;
        int img = pp < nb_img ? pp : nb_img - 1;
        VkImageAspectFlags aspect = VK_IMAGE_ASPECT_COLOR_BIT;
        if (nb_img == 1 && planes > 1)
            aspect = pp == 0 ? VK_IMAGE_ASPECT_PLANE_0_BIT : pp == 1 ? VK_IMAGE_ASPECT_PLANE_1_BIT
                                                                   : VK_IMAGE_ASPECT_PLANE_2_BIT;
        VkImageViewCreateInfo vi = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = vkf->img[img],
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = nb_img == 1 && planes > 1 ? plane_format(bits16, comps) : vkfc->format[img],
            .subresourceRange = {aspect, 0, 1, 0, 1},
        };
        if (r->CreateImageView(r->device, &vi, NULL, &s->views[p]) != VK_SUCCESS) return AVERROR_EXTERNAL;
        infos[p] = (VkDescriptorImageInfo) {r->sampler, s->views[p], VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    }
    VkWriteDescriptorSet w = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = s->set,
        .dstBinding = 0,
        .descriptorCount = MAX_PLANES,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = infos,
    };
    r->UpdateDescriptorSets(r->device, 1, &w, 0, NULL);

    // Geometry: fit/fill with optional rotation; the picture keeps its display aspect ratio.
    double sar = frame->sample_aspect_ratio.num > 0 && frame->sample_aspect_ratio.den > 0
                     ? av_q2d(frame->sample_aspect_ratio) : 1.0;
    double vw = frame->width * sar, vh = frame->height;
    int rot = ((view ? view->rotation : 0) % 360 + 360) % 360;
    if (rot == 90 || rot == 270) {
        double t = vw;
        vw = vh;
        vh = t;
    }
    double W = r->extent.width, H = r->extent.height;
    double fit = fmin(W / vw, H / vh), fill = fmax(W / vw, H / vh);
    double zoom = view ? fmin(fmax(view->zoom, 0.0), 1.0) : 0.0;
    double sc = fit + (fill - fit) * zoom;
    double hx = vw * sc / W, hy = vh * sc / H;   // half extents in NDC
    double us = (double) frame->width / fc->width, vs = (double) frame->height / fc->height;

    PushConstants pc = {
        .dst = {(float) -hx, (float) -hy, (float) hx, (float) hy},
        .mode = semi ? 1 : 0,
    };
    switch (rot) {   // u,v as functions of the on-screen s,t in [0,1]
    case 90:
        pc.uvx[0] = 0, pc.uvx[1] = 0, pc.uvx[2] = us;
        pc.uvy[0] = vs, pc.uvy[1] = -vs, pc.uvy[2] = 0;
        break;
    case 180:
        pc.uvx[0] = us, pc.uvx[1] = -us, pc.uvx[2] = 0;
        pc.uvy[0] = vs, pc.uvy[1] = 0, pc.uvy[2] = -vs;
        break;
    case 270:
        pc.uvx[0] = us, pc.uvx[1] = 0, pc.uvx[2] = -us;
        pc.uvy[0] = 0, pc.uvy[1] = vs, pc.uvy[2] = 0;
        break;
    default:
        pc.uvx[0] = 0, pc.uvx[1] = us, pc.uvx[2] = 0;
        pc.uvy[0] = 0, pc.uvy[1] = 0, pc.uvy[2] = vs;
    }
    double container = bits16 ? 65535.0 : 255.0;
    double code_max = (double) ((1 << depth) - 1) * (1 << d->comp[0].shift);
    pc.scale[0] = pc.scale[1] = (float) (container / code_max);
    pc.scale[2] = 1.0f / (float) ((1 << r->out_bits) - 1);
    pc.scale[3] = (float) (r->frame_no++ % 251) * 3.7f;
    color_matrix(frame, depth, &pc);

    // Record.
    VkCommandBuffer cmd = s->cmd;
    r->ResetCommandBuffer(cmd, 0);
    VkCommandBufferBeginInfo bi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    r->BeginCommandBuffer(cmd, &bi);

    vkfc->lock_frame(fc, vkf);
    VkImageMemoryBarrier2 bars[AV_NUM_DATA_POINTERS + 1];
    VkSemaphoreSubmitInfo waits[AV_NUM_DATA_POINTERS + 1], signals[AV_NUM_DATA_POINTERS + 1];
    int nb = 0;
    for (int i = 0; i < nb_img; i++) {
        uint32_t qf = vkf->queue_family[i];
        bars[nb++] = (VkImageMemoryBarrier2) {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
            .srcAccessMask = vkf->access[i],
            .dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .dstAccessMask = VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
            .oldLayout = vkf->layout[i],
            .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = qf == (uint32_t) r->qf ? VK_QUEUE_FAMILY_IGNORED : qf,
            .dstQueueFamilyIndex = qf == (uint32_t) r->qf || qf == VK_QUEUE_FAMILY_IGNORED
                                       ? VK_QUEUE_FAMILY_IGNORED : (uint32_t) r->qf,
            .image = vkf->img[i],
            .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
        };
        if (nb_img == 1 && planes > 1) {
            bars[nb - 1].subresourceRange.aspectMask =
                VK_IMAGE_ASPECT_PLANE_0_BIT | VK_IMAGE_ASPECT_PLANE_1_BIT | (planes > 2 ? VK_IMAGE_ASPECT_PLANE_2_BIT : 0);
        }
        waits[i] = (VkSemaphoreSubmitInfo) {
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = vkf->sem[i],
            .value = vkf->sem_value[i],
            .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        };
        signals[i] = (VkSemaphoreSubmitInfo) {
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = vkf->sem[i],
            .value = vkf->sem_value[i] + 1,
            .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        };
    }
    bars[nb++] = (VkImageMemoryBarrier2) {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = r->images[idx],
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    VkDependencyInfo dep = {
        .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = nb,
        .pImageMemoryBarriers = bars,
    };
    r->CmdPipelineBarrier2(cmd, &dep);

    VkRenderingAttachmentInfo att = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = r->image_views[idx],
        .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = {.color = {.float32 = {0, 0, 0, 1}}},
    };
    VkRenderingInfo rinfo = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = {{0, 0}, r->extent},
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &att,
    };
    r->CmdBeginRendering(cmd, &rinfo);
    VkViewport vp = {0, 0, (float) r->extent.width, (float) r->extent.height, 0, 1};
    VkRect2D scissor = {{0, 0}, r->extent};
    r->CmdSetViewport(cmd, 0, 1, &vp);
    r->CmdSetScissor(cmd, 0, 1, &scissor);
    r->CmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, r->pipeline);
    r->CmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, r->layout, 0, 1, &s->set, 0, NULL);
    r->CmdPushConstants(cmd, r->layout, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0,
                        sizeof(pc), &pc);
    r->CmdDraw(cmd, 4, 1, 0, 0);
    r->CmdEndRendering(cmd);

    VkImageMemoryBarrier2 present = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        .dstStageMask = VK_PIPELINE_STAGE_2_NONE,
        .dstAccessMask = 0,
        .oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = r->images[idx],
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    VkDependencyInfo dep2 = {
        .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &present,
    };
    r->CmdPipelineBarrier2(cmd, &dep2);
    r->EndCommandBuffer(cmd);

    waits[nb_img] = (VkSemaphoreSubmitInfo) {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .semaphore = s->acquired,
        .stageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
    };
    signals[nb_img] = (VkSemaphoreSubmitInfo) {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .semaphore = r->rendered[idx],
        .stageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
    };
    VkCommandBufferSubmitInfo cbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, .commandBuffer = cmd};
    VkSubmitInfo2 submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .waitSemaphoreInfoCount = nb_img + 1,
        .pWaitSemaphoreInfos = waits,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &cbi,
        .signalSemaphoreInfoCount = nb_img + 1,
        .pSignalSemaphoreInfos = signals,
    };
    queue_lock(r);
    res = r->QueueSubmit2(r->queue, 1, &submit, s->fence);
    if (res == VK_SUCCESS) {
        for (int i = 0; i < nb_img; i++) {
            vkf->sem_value[i]++;
            vkf->layout[i] = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            vkf->access[i] = VK_ACCESS_2_SHADER_SAMPLED_READ_BIT;
        }
    }
    vkfc->unlock_frame(fc, vkf);
    if (res != VK_SUCCESS) {
        queue_unlock(r);
        LOGE("vkQueueSubmit2 failed (%d)", res);
        return AVERROR_EXTERNAL;
    }
    s->busy = 1;
    s->hold = av_frame_clone(frame);
    r->slot = (r->slot + 1) % SLOTS;

    VkPresentInfoKHR pi = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &r->rendered[idx],
        .swapchainCount = 1,
        .pSwapchains = &r->swapchain,
        .pImageIndices = &idx,
    };
    res = r->QueuePresentKHR(r->queue, &pi);
    queue_unlock(r);
    if (res == VK_ERROR_OUT_OF_DATE_KHR || res == VK_SUBOPTIMAL_KHR) r->dirty = 1;
    else if (res != VK_SUCCESS) return AVERROR_EXTERNAL;
    return 0;
}

int vkr_draw(VkRender *r, const AVFrame *frame, const VkrView *view) {
    AVFrame *vk = frame->format == AV_PIX_FMT_VULKAN ? av_frame_clone(frame) : upload(r, frame);
    if (!vk) return AVERROR(EINVAL);
    av_frame_free(&r->last);
    r->last = vk;   // shown as soon as a window arrives (vkr_redraw)
    if (!r->window) return 0;
    int ret = render(r, vk, view);
    if (ret == AVERROR(EAGAIN)) ret = render(r, vk, view);   // swapchain was out of date
    return ret;
}

int vkr_redraw(VkRender *r, const VkrView *view) {
    if (!r->last || !r->window) return 0;
    int ret = render(r, r->last, view);
    if (ret == AVERROR(EAGAIN)) ret = render(r, r->last, view);
    return ret;
}

void vkr_destroy(VkRender *r) {
    if (!r) return;
    if (r->ready) {
        destroy_surface(r);
        av_frame_free(&r->last);
        av_frame_free(&r->converted);
        sws_free_context(&r->sws);
        av_buffer_unref(&r->upload_fc);
        if (r->pipeline) r->DestroyPipeline(r->device, r->pipeline, NULL);
        for (int i = 0; i < SLOTS; i++) {
            if (r->slots[i].fence) r->DestroyFence(r->device, r->slots[i].fence, NULL);
            if (r->slots[i].acquired) r->DestroySemaphore(r->device, r->slots[i].acquired, NULL);
        }
        if (r->pool) r->DestroyCommandPool(r->device, r->pool, NULL);
        if (r->dpool) r->DestroyDescriptorPool(r->device, r->dpool, NULL);
        if (r->vert) r->DestroyShaderModule(r->device, r->vert, NULL);
        if (r->frag) r->DestroyShaderModule(r->device, r->frag, NULL);
        if (r->layout) r->DestroyPipelineLayout(r->device, r->layout, NULL);
        if (r->dsl) r->DestroyDescriptorSetLayout(r->device, r->dsl, NULL);
        if (r->sampler) r->DestroySampler(r->device, r->sampler, NULL);
    }
    if (r->window) ANativeWindow_release(r->window);
    av_buffer_unref(&r->dev_ref);
    av_free(r);
}
