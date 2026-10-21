//! AVIF via ravif (rav1e AV1 encoder).

use image::DynamicImage;
use imgref::Img;
use ravif::{AlphaColorMode, Encoder};
use rgb::FromSlice;

use crate::engine::{EngineError, Settings};

pub fn encode(image: &DynamicImage, settings: &Settings) -> Result<Vec<u8>, EngineError> {
    let quality = if settings.lossless { 100.0 } else { settings.quality.clamp(1, 100) as f32 };
    let encoder = Encoder::new()
        .with_quality(quality)
        .with_alpha_quality(quality)
        .with_speed(match settings.effort {
            0 => 8,
            1 => 6,
            _ => 4,
        })
        .with_alpha_color_mode(AlphaColorMode::UnassociatedClean)
        .with_num_threads(None);

    let width = image.width() as usize;
    let height = image.height() as usize;
    let encoded = if image.color().has_alpha() {
        let rgba = image.to_rgba8();
        encoder.encode_rgba(Img::new(rgba.as_raw().as_rgba(), width, height))
    } else {
        let rgb = image.to_rgb8();
        encoder.encode_rgb(Img::new(rgb.as_raw().as_rgb(), width, height))
    };
    encoded
        .map(|e| e.avif_file)
        .map_err(|e| EngineError::Encode(format!("ravif: {e}")))
}
