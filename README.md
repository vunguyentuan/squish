# Squish

A native macOS image and video optimizer: a SwiftUI (Liquid Glass) app on top of a Rust image engine
and Apple's hardware video encoder.

**[Download for Mac](https://github.com/vunguyentuan/squish/releases/latest/download/Squish.zip)** (macOS 26+, Apple Silicon, notarized) · **[Website](https://squish.madebyvu.com)**

![Squish](site/public/assets/app-window.webp)

## Build from source

```
make run       # build the Rust engine + app → build/Squish.app, then launch
make install   # copy to /Applications (enables Finder Services + Launch at Login)
make test      # engine tests
make release   # Developer ID sign + notarize → build/Squish.zip (needs your own certificate)
```

Requires macOS 26+, Xcode 26+, Rust (Homebrew or rustup).

## Engine (`core/`, Rust → `libsquish_core.a`, C ABI in `core/include/squish_core.h`)

| Format | Lossy | Lossless |
|---|---|---|
| PNG | libimagequant palette quantization → oxipng | oxipng (Zopfli at *Maximum*), APNG-safe |
| JPEG | mozjpeg trellis re-encode, *and* lossless transcode — smaller wins | jpegtran-style DCT transcode + progressive scan search (pixel-identical) |
| WebP | libwebp method 6, sharp YUV | VP8L re-encode for lossless sources |
| SVG | OXVG (Rust port of SVGO) | — |
| → WebP / AVIF / JPEG | conversion from PNG, JPEG, TIFF, BMP, GIF, HEIC*, AVIF* | |

\* HEIC/AVIF are decoded by ImageIO in the app and handed to the engine as PNG.

Rules: a file is never made bigger (the original is left untouched), photo orientation
survives metadata stripping, ICC profiles are kept by default.

CLI harness: `cargo run --release --example squish -- -q 80 -f webp image.png`

## Video (`App/Sources/Squish/Engine/VideoWork.swift`, AVFoundation)

MOV, MP4 and M4V are re-encoded to HEVC (`hvc1`) with VideoToolbox at constant quality, in the
same container. Resolution, frame rate, rotation and colour are kept; HDR (HLG/PQ) stays 10-bit.
AAC audio is copied, other mono/stereo audio becomes AAC, surround is copied as is. Output is
fast-start (index first) for the web. A video is only replaced if it shrinks by at least 10%, and
Squish tags its own output ("encoding software: Squish") so dropping it again doesn't re-encode it.
Lossless mode skips videos. Videos encode one at a time (they share the hardware encoder);
Fast/Balanced effort lets the encoder prioritize speed (~1.75× faster, ~6% larger), Maximum doesn't.

## App (`App/`, SwiftPM)

- **Drop anywhere** in the window, on the Dock icon, via *Open With*, Finder *Services → Optimize with Squish*, or ⌘O.
- **Shake to Drop**: shake the cursor while dragging files in any app; a glass shelf appears
  under the cursor. Drop, watch it squish, then drag the optimized files straight back out.
  Works with no Accessibility permission (mouse-down monitor + cursor sampling + drag pasteboard).
- **Safe replace**: originals are cloned (free on APFS) into the Trash; *Restore* puts them back.
  Finder tags, creation date and permissions are preserved.
- Space for **Quick Look**, before/after **compare slider** (images), inline **Convert** for HEIC/TIFF, presets (Lossless / Balanced / Smallest),
  menu bar extra, `squish://shelf` and `squish://open` URLs, Launch at Login.

## Layout

```
core/src/      lib.rs (FFI) · engine.rs (dispatch) · png_opt · jpeg · webp_opt · avif · svg · decode · exif · format
App/Sources/   Engine/ (Swift bridge) · Model/ (queue, file ops, prefs) · Shake/ (detector, shelf panel) · Views/
scripts/       build-app.sh (bundle + ad-hoc sign) · release.sh (notarize) · make-icon.swift (renders the icon)
site/          landing page
```

The landing page lives in `site/` (Cloudflare Workers static assets: `cd site && wrangler deploy`).

## License

Squish is free software under the [GNU GPL v3.0](LICENSE). It links libimagequant (GPL-3.0),
mozjpeg (IJG/BSD), libwebp (BSD), rav1e (BSD-2-Clause), oxipng (MIT) and OXVG (MIT).
