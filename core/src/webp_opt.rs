//! WebP via libwebp: method 6, sharp YUV and exact-free alpha for the best ratio.

use image::DynamicImage;
use webp::{Encoder, WebPConfig};

use crate::decode;
use crate::engine::{EngineError, Settings};
use crate::format;

/// Re-encodes an existing WebP. Lossless sources stay lossless.
pub fn reencode(data: &[u8], settings: &Settings) -> Result<Vec<u8>, EngineError> {
    if format::is_animated_webp(data) {
        return Err(EngineError::Unsupported("Animated WebP is not supported yet".into()));
    }
    let source_lossless = format::is_lossless_webp(data);
    if settings.lossless && !source_lossless {
        // Nothing to gain losslessly from an already-lossy bitstream.
        return Ok(data.to_vec());
    }
    let raster = decode::decode(data)?;
    encode(&raster.image, settings.lossless || source_lossless, settings)
}

pub fn encode(image: &DynamicImage, lossless: bool, settings: &Settings) -> Result<Vec<u8>, EngineError> {
    let rgba;
    let rgb;
    let encoder = if image.color().has_alpha() {
        rgba = image.to_rgba8();
        Encoder::from_rgba(rgba.as_raw(), rgba.width(), rgba.height())
    } else {
        rgb = image.to_rgb8();
        Encoder::from_rgb(rgb.as_raw(), rgb.width(), rgb.height())
    };

    let mut config = WebPConfig::new().map_err(|_| EngineError::Encode("libwebp: bad config".into()))?;
    config.method = match settings.effort {
        0 => 4,
        1 => 5,
        _ => 6,
    };
    config.thread_level = 1;
    if lossless {
        config.lossless = 1;
        // For lossless, "quality" is compression effort.
        config.quality = match settings.effort {
            0 => 50.0,
            1 => 80.0,
            _ => 100.0,
        };
        config.exact = 0;
    } else {
        config.lossless = 0;
        config.quality = settings.quality.clamp(1, 100) as f32;
        config.use_sharp_yuv = 1;
        config.alpha_quality = 100;
        config.pass = if settings.effort >= 2 { 6 } else { 1 };
    }
    encoder
        .encode_advanced(&config)
        .map(|m| m.to_vec())
        .map_err(|e| EngineError::Encode(format!("libwebp: {e:?}")))
}
