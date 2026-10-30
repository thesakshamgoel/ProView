#!/bin/zsh
# Builds a trimmed, LGPL, static FFmpeg for arm64 Android, used by ProView's native engine.
set -e
SRC=${FFMPEG_SRC:-$HOME/Development/ffmpeg-9.0.2}
NDK=${ANDROID_NDK:-$HOME/Library/Android/sdk/ndk/27.2.12479018}
API=29
OUT=${1:?usage: build_ffmpeg_android.sh <install-dir>}
TC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64
BUILD=$HOME/Development/build-ffmpeg-android
# Vulkan (GPU ProRes decoding) needs headers >= 1.3.277 and glslang to compile FFmpeg's shaders.
VK=${VULKAN_HEADERS:-$HOME/Development/vk/Vulkan-Headers-1.4.328/include}
GLSLANG=${GLSLANG:-$HOME/Development/vk/glslang/bin/glslang}
rm -rf $BUILD && mkdir -p $BUILD && cd $BUILD

$SRC/configure \
  --prefix=$OUT \
  --target-os=android --arch=aarch64 --cpu=armv8-a --enable-cross-compile \
  --cc=$TC/bin/aarch64-linux-android$API-clang \
  --cxx=$TC/bin/aarch64-linux-android$API-clang++ \
  --ar=$TC/bin/llvm-ar --nm=$TC/bin/llvm-nm --ranlib=$TC/bin/llvm-ranlib --strip=$TC/bin/llvm-strip \
  --sysroot=$TC/sysroot \
  --extra-cflags="-O3 -fPIC -fvisibility=hidden -I$VK" \
  --enable-pic --enable-static --disable-shared \
  --disable-programs --disable-doc --disable-debug --disable-network \
  --disable-autodetect --enable-zlib \
  --enable-vulkan --glslc=$GLSLANG \
  --disable-everything \
  --enable-hwaccel=prores_vulkan \
  --disable-avdevice --disable-avfilter \
  --enable-avformat --enable-avcodec --enable-swscale --enable-swresample \
  --enable-protocol=file,fd \
  --enable-demuxer=mov,matroska,mxf,avi,mpegts,mpegps,m4v,hevc,h264,wav,aiff \
  --enable-muxer=mp4,mov \
  --enable-decoder=prores,hevc,h264,mpeg4,mpeg2video,vp8,vp9,dnxhd,cfhd,mjpeg,png,ffv1,aac,aac_latm,alac,mp3,mp3float,ac3,eac3,flac,opus,vorbis,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_s8,pcm_u8 \
  --enable-encoder=aac \
  --enable-parser=hevc,h264,aac,ac3,mpeg4video,mpegvideo,vp9,opus,flac,mpegaudio,dnxhd,mjpeg \
  --enable-bsf=aac_adtstoasc,hevc_mp4toannexb,extract_extradata \
  > configure.log

make -j$(sysctl -n hw.ncpu) > make.log 2>&1
make install > install.log 2>&1
echo "FFmpeg for Android installed to $OUT"
