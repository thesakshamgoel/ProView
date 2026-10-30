# ProView

An Android video player and library for pro formats that phones usually can't handle: **ProRes**, **HEVC 4:2:2 10-bit**, H.264, DNxHD/HR, CineForm and VP9 in MOV, MP4, MKV and MXF. Flutter UI in an Apple "Liquid Glass" style, Kotlin for the Android side, and a C engine (FFmpeg + Vulkan) for decoding and 10-bit output. Windows support is planned from the same code.

## What it does
- Plays pro-format clips with a GPU (Vulkan) 10-bit renderer; makes a smooth phone-playable copy when a clip is too heavy to decode live.
- Library with date sections, sorting, pinch-to-resize tiles, multi-select (drag to select), favourites, Bin, folders and USB drives.
- Smart Search: formats, sizes, dates, and (on-device, ML Kit) people, text and things in the picture.
- Player gestures: swipe left/right for next/previous video, vertical swipes for volume (left) and brightness (right), swipe down to close, double-tap to seek.
- Requests the screen's highest refresh rate (120 Hz) except in Power saving mode.

## Layout
| Folder | What's in it |
| --- | --- |
| `proview/` | The Flutter app (`lib/`), Android project (`android/`) and Windows runner (`windows/`) |
| `proview/android/app/src/main/cpp/` | Native engine: player, converter and Vulkan renderer (C) |
| `proview_native/` | `build_ffmpeg_android.sh`: builds the trimmed LGPL FFmpeg the engine links against |
| `Logos/` | The logo (`Logo 1.png` is used unchanged for the app icon, splash and in-app mark) |

## Building (Android, arm64)
1. Install Flutter, JDK 17, the Android SDK with NDK 27.2.12479018 and CMake 3.22.1.
2. Build FFmpeg (needs the Vulkan headers and `glslang`; see the variables at the top of the script):
   `proview_native/build_ffmpeg_android.sh <proview/android/app/src/main/cpp/ffmpeg/arm64-v8a>`
3. From `proview/`: `python3 tool/gen_icons.py` (only if the logo changed), then
   `flutter build apk --release --target-platform android-arm64`

The FFmpeg libraries are not committed; step 2 regenerates them. GPU ProRes decoding through FFmpeg's Vulkan path is off by default because it crashes Adreno's shader compiler.

## Notes
- No license has been chosen yet. FFmpeg is built as LGPL.
- `ProView.apk` builds are not committed.
