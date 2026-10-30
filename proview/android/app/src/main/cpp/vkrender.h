// ProView GPU video output: draws FFmpeg frames (GPU-decoded Vulkan images or uploaded software frames)
// to an ANativeWindow through a 10-bit Vulkan swapchain. YCbCr->RGB, scaling and dithering run in a
// fragment shader. All calls except vkr_create/vkr_destroy must come from one thread.
#pragma once

#include <android/native_window.h>
#include <libavutil/buffer.h>
#include <libavutil/frame.h>

typedef struct VkRender VkRender;

typedef struct VkrView {
    float zoom;     // 0 = fit the whole picture, 1 = fill the screen (crops), in between animates
    int rotation;   // clockwise degrees to rotate the picture: 0, 90, 180 or 270
} VkrView;

// Creates the Vulkan device shared with FFmpeg's GPU decoders. Returns NULL if Vulkan isn't usable.
VkRender *vkr_create(void);
void vkr_destroy(VkRender *r);

// The AVHWDeviceContext to hand to avcodec for GPU decoding.
AVBufferRef *vkr_device(VkRender *r);

// Attaches a window (NULL detaches). Recreates the swapchain if the window or its size changed.
void vkr_set_window(VkRender *r, ANativeWindow *win, int width, int height);

// Draws a frame (AV_PIX_FMT_VULKAN or a software YCbCr frame) and presents it. Keeps a reference
// so vkr_redraw can repaint it (after a resize or zoom change while paused). Returns 0 or AVERROR.
int vkr_draw(VkRender *r, const AVFrame *frame, const VkrView *view);
int vkr_redraw(VkRender *r, const VkrView *view);

// Bits per channel of the current swapchain (10 when the display path is 10-bit), 0 if none yet.
int vkr_output_bits(VkRender *r);
