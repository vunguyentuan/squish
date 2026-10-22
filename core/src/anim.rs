//! Animated GIF → animated WebP through libwebp's WebPAnimEncoder.
//!
//! Frames are streamed from the GIF decoder (already composited onto the full canvas) and
//! handed to the encoder one at a time, so long GIFs never sit in memory as raw RGBA.

use std::io::Cursor;
use std::mem::MaybeUninit;

use image::codecs::gif::GifDecoder;
use image::{AnimationDecoder, DynamicImage, ImageDecoder};
use libwebp_sys as ffi;

use crate::engine::{EngineError, Settings};
use crate::resize;

pub struct Animation {
    pub data: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Browsers play GIF delays of 10 ms or less at 100 ms; keep that timing.
fn frame_delay_ms(numer: u32, denom: u32) -> i32 {
    let ms = numer.checked_div(denom).unwrap_or(0);
    if ms <= 10 { 100 } else { ms.min(60_000) as i32 }
}

pub fn gif_to_webp(data: &[u8], settings: &Settings) -> Result<Animation, EngineError> {
    let decode_err = |e: image::ImageError| EngineError::Decode(e.to_string());
    let decoder = GifDecoder::new(Cursor::new(data)).map_err(decode_err)?;
    let (src_width, src_height) = decoder.dimensions();
    let (width, height) = resize::fit(src_width, src_height, settings.max_dimension).unwrap_or((src_width, src_height));

    let mut encoder = AnimEncoder::new(width, height, settings)?;
    let mut timestamp = 0i32;
    for frame in decoder.into_frames() {
        let frame = frame.map_err(decode_err)?;
        let (numer, denom) = frame.delay().numer_denom_ms();
        let mut rgba = frame.into_buffer();
        if (width, height) != (src_width, src_height) {
            rgba = resize::downscale(&DynamicImage::ImageRgba8(rgba), width, height)?.into_rgba8();
        }
        encoder.add(rgba.as_raw(), timestamp)?;
        timestamp = timestamp.saturating_add(frame_delay_ms(numer, denom));
    }
    Ok(Animation { data: encoder.finish(timestamp)?, width, height })
}

/// Owns a `WebPAnimEncoder` and frees it on every path.
struct AnimEncoder {
    raw: *mut ffi::WebPAnimEncoder,
    config: ffi::WebPConfig,
    width: u32,
    height: u32,
}

impl AnimEncoder {
    fn new(width: u32, height: u32, settings: &Settings) -> Result<Self, EngineError> {
        let config_err = || EngineError::Encode("libwebp: bad animation config".into());
        let mut options = MaybeUninit::<ffi::WebPAnimEncoderOptions>::uninit();
        let mut config = MaybeUninit::<ffi::WebPConfig>::uninit();
        unsafe {
            if ffi::WebPAnimEncoderOptionsInitInternal(options.as_mut_ptr(), ffi::WEBP_MUX_ABI_VERSION as _) == 0 {
                return Err(config_err());
            }
            let quality = settings.quality.clamp(1, 100) as f32;
            if ffi::WebPConfigInitInternal(
                config.as_mut_ptr(),
                ffi::WebPPreset::WEBP_PRESET_DEFAULT,
                quality,
                ffi::WEBP_ENCODER_ABI_VERSION as _,
            ) == 0
            {
                return Err(config_err());
            }
        }
        let mut options = unsafe { options.assume_init() };
        let mut config = unsafe { config.assume_init() };

        options.anim_params.loop_count = 0;
        // Mixed mode lets each frame pick lossy or lossless, whichever is smaller.
        options.allow_mixed = i32::from(!settings.lossless);
        options.minimize_size = i32::from(settings.effort >= 2);
        config.lossless = i32::from(settings.lossless);
        config.method = match settings.effort {
            0 => 2,
            1 => 4,
            _ => 6,
        };
        if settings.lossless {
            config.quality = 75.0;
        }
        config.thread_level = 1;

        let raw = unsafe {
            ffi::WebPAnimEncoderNewInternal(width as i32, height as i32, &options, ffi::WEBP_MUX_ABI_VERSION as _)
        };
        if raw.is_null() {
            return Err(EngineError::Encode("libwebp: couldn't create the animation encoder".into()));
        }
        Ok(Self { raw, config, width, height })
    }

    fn add(&mut self, rgba: &[u8], timestamp: i32) -> Result<(), EngineError> {
        let mut picture = ffi::WebPPicture::new().map_err(|_| EngineError::Encode("libwebp: bad picture".into()))?;
        picture.use_argb = 1;
        picture.width = self.width as i32;
        picture.height = self.height as i32;
        let ok = unsafe {
            ffi::WebPPictureImportRGBA(&mut picture, rgba.as_ptr(), (self.width * 4) as i32) != 0
                && ffi::WebPAnimEncoderAdd(self.raw, &mut picture, timestamp, &self.config) != 0
        };
        unsafe { ffi::WebPPictureFree(&mut picture) };
        if ok { Ok(()) } else { Err(self.error()) }
    }

    /// `end` is when the last frame stops showing, which sets its duration.
    fn finish(self, end: i32) -> Result<Vec<u8>, EngineError> {
        let mut data = ffi::WebPData::default();
        unsafe {
            if ffi::WebPAnimEncoderAdd(self.raw, std::ptr::null_mut(), end, std::ptr::null()) == 0
                || ffi::WebPAnimEncoderAssemble(self.raw, &mut data) == 0
            {
                return Err(self.error());
            }
            let bytes = std::slice::from_raw_parts(data.bytes, data.size).to_vec();
            ffi::WebPDataClear(&mut data);
            Ok(bytes)
        }
    }

    fn error(&self) -> EngineError {
        let message = unsafe { ffi::WebPAnimEncoderGetError(self.raw) };
        let detail = if message.is_null() {
            "unknown error".into()
        } else {
            unsafe { std::ffi::CStr::from_ptr(message) }.to_string_lossy().into_owned()
        };
        EngineError::Encode(format!("libwebp: {detail}"))
    }
}

impl Drop for AnimEncoder {
    fn drop(&mut self) {
        unsafe { ffi::WebPAnimEncoderDelete(self.raw) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::format;
    use image::codecs::gif::{GifEncoder, Repeat};
    use image::{Delay, Frame, Rgba, RgbaImage};

    fn animated_gif(frames: u32) -> Vec<u8> {
        let mut out = Vec::new();
        {
            let mut encoder = GifEncoder::new(&mut out);
            encoder.set_repeat(Repeat::Infinite).unwrap();
            for i in 0..frames {
                let image = RgbaImage::from_fn(64, 48, |x, y| Rgba([(x * 4) as u8, (y * 5) as u8, (i * 40) as u8, 255]));
                encoder
                    .encode_frame(Frame::from_parts(image, 0, 0, Delay::from_numer_denom_ms(80, 1)))
                    .unwrap();
            }
        }
        out
    }

    fn settings() -> Settings {
        Settings {
            quality: 80,
            lossless: false,
            strip_metadata: true,
            keep_color_profile: true,
            effort: 1,
            target: format::Format::WebP,
            max_dimension: 0,
        }
    }

    #[test]
    fn converts_to_animated_webp() {
        let animation = gif_to_webp(&animated_gif(4), &settings()).unwrap();
        assert_eq!((animation.width, animation.height), (64, 48));
        assert_eq!(format::detect(&animation.data), format::Format::WebP);
        assert!(format::is_animated_webp(&animation.data));
    }

    #[test]
    fn resizes_every_frame() {
        let settings = Settings { max_dimension: 32, ..settings() };
        let animation = gif_to_webp(&animated_gif(3), &settings).unwrap();
        assert_eq!((animation.width, animation.height), (32, 24));
    }

    #[test]
    fn clamps_tiny_delays_like_browsers() {
        assert_eq!(frame_delay_ms(0, 1), 100);
        assert_eq!(frame_delay_ms(10, 1), 100);
        assert_eq!(frame_delay_ms(40, 1), 40);
    }
}
