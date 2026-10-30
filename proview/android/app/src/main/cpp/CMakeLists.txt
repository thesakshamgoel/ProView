cmake_minimum_required(VERSION 3.22.1)
project(proview C)

set(FFMPEG_DIR ${CMAKE_CURRENT_SOURCE_DIR}/ffmpeg/${ANDROID_ABI})

add_library(proview SHARED proview_engine.c player.c vkrender.c)
target_include_directories(proview PRIVATE ${FFMPEG_DIR}/include)
target_compile_options(proview PRIVATE -O2 -Wall -Wno-deprecated-declarations)

# Static FFmpeg (with its Vulkan ProRes decoder; libvulkan is loaded at runtime), linked in dependency
# order; keep its symbols private to this library.
target_link_libraries(proview
    ${FFMPEG_DIR}/lib/libavformat.a
    ${FFMPEG_DIR}/lib/libavcodec.a
    ${FFMPEG_DIR}/lib/libswscale.a
    ${FFMPEG_DIR}/lib/libswresample.a
    ${FFMPEG_DIR}/lib/libavutil.a
    mediandk aaudio android log dl z m)
target_link_options(proview PRIVATE
    -Wl,--exclude-libs,ALL
    -Wl,-Bsymbolic
    -Wl,-z,max-page-size=16384)
