# Neon Video Compressor

An iOS app that compresses recorded videos to **HEVC** using a self-built,
minimal **FFmpeg + libx265 4.2**, with live progress, pause/resume/cancel, and
Apple AudioToolbox AAC (including HE-AAC).

It reproduces the equivalent of:

```
ffmpeg -i in.mp4 -c:v libx265 -crf 30 -preset slow -tag:v hvc1 \
       -c:a aac -b:a 40k -movflags +faststart in_hevc.mp4
```

## Building the native dependencies

The XCFrameworks are **not** checked in — build them once before opening Xcode:

```sh
scripts/build-all.sh          # builds x265 4.2 + minimal FFmpeg for iOS
```

This produces:

- `Frameworks/x265.xcframework`  (iphoneos arm64 + iphonesimulator arm64)
- `Frameworks/FFmpeg.xcframework` (merged libav* static libs)

Requirements: Xcode + command line tools, `cmake`, `nasm`, `git`. Override
versions with env vars, e.g. `X265_TAG=4.2 FFMPEG_TAG=n7.1 scripts/build-all.sh`.

> **NEON note:** x265's ARM64 assembly rule doesn't pass `-arch`/`-isysroot` on
> Apple; `build-x265.sh` seeds `ASM_FLAGS` to fix this so the NEON kernels (the
> reason for wanting 4.2) actually build for the device target.

Then open `Neon Video Compressor.xcodeproj` and run on a **physical device**
(HEVC encoding uses NEON and is device-only; the simulator slice is for UI work).

## Architecture

- `Engine/Transcoder.{hpp,cpp}` — a custom libav\* transcode loop. It is *not*
  the `ffmpeg` CLI, because the CLI can't pause and gives only coarse progress.
  The loop checks a pause condition-variable and a cancel flag each iteration,
  and reports processed-seconds / speed / ETA.
- `Engine/TranscodeEngine.{h,mm}` — thin Objective-C++ bridge to Swift.
- `Models/`, `Views/` — SwiftUI. `SetupView` picks a video (Photos or Files) and
  chooses options; `ProgressView2` shows progress and manages background time.

Video: `libx265` (`crf`, `preset`, `hvc1` tag). Audio: `aac_at` (AudioToolbox)
for AAC-LC / HE-AAC / HE-AAC v2. Output: MP4 with `+faststart`. Per-stream copy
paths implement "video only" / "audio only".

## Known limitations

- **Background:** iOS only grants ~30 s of on-demand background CPU. The app
  keeps encoding while backgrounded for as long as the OS allows, then
  auto-pauses (checkpoint in memory) and resumes when you return. If the OS fully
  suspends/kills the app, an in-flight encode is lost — x265 has no resume.
- **HE-AAC** relies on Apple's AudioToolbox encoder; verify on-device behavior at
  very low bitrates.

## Licensing

x265 is **GPLv2**, so this FFmpeg build (and therefore the app binary) is GPL.
That is fine for personal/sideloaded use but is generally **incompatible with
App Store distribution terms**. Do not ship this to the App Store as-is.
