//! Generic raster decoding for format conversion.

use std::io::Cursor;

use image::{DynamicImage, ImageDecoder, ImageReader};

use crate::engine::EngineError;

pub struct Raster {
    pub image: DynamicImage,
    pub icc: Option<Vec<u8>>,
}

/// Decodes any supported raster and bakes EXIF orientation into the pixels.
pub fn decode(data: &[u8]) -> Result<Raster, EngineError> {
    let reader = ImageReader::new(Cursor::new(data))
        .with_guessed_format()
        .map_err(|e| EngineError::Decode(e.to_string()))?;
    let mut decoder = reader.into_decoder().map_err(|e| EngineError::Decode(e.to_string()))?;
    let orientation = decoder.orientation().unwrap_or(image::metadata::Orientation::NoTransforms);
    let icc = decoder.icc_profile().ok().flatten();
    let mut image = DynamicImage::from_decoder(decoder).map_err(|e| EngineError::Decode(e.to_string()))?;
    image.apply_orientation(orientation);
    Ok(Raster { image, icc })
}

pub fn dimensions(data: &[u8]) -> Option<(u32, u32)> {
    ImageReader::new(Cursor::new(data)).with_guessed_format().ok()?.into_dimensions().ok()
}
