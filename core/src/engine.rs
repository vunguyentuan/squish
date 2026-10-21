//! Format dispatch and the "never make a file bigger" rule.

use crate::format::{self, Format};
use crate::{avif, decode, jpeg, png_opt, svg, webp_opt};

#[derive(Clone, Copy, Debug)]
pub struct Settings {
    pub quality: u8,
    pub lossless: bool,
    pub strip_metadata: bool,
    pub keep_color_profile: bool,
    /// 0 = fast, 1 = balanced, 2 = maximum.
    pub effort: u8,
    /// `Format::Unknown` keeps the source format.
    pub target: Format,
}

#[derive(Debug)]
pub enum EngineError {
    Io(String),
    Unsupported(String),
    Decode(String),
    Encode(String),
}

impl EngineError {
    pub fn message(&self) -> &str {
        match self {
            Self::Io(m) | Self::Unsupported(m) | Self::Decode(m) | Self::Encode(m) => m,
        }
    }
}

pub struct Outcome {
    /// `None` when the original is already as small as we can make it.
    pub data: Option<Vec<u8>>,
    pub input_format: Format,
    pub output_format: Format,
    pub width: u32,
    pub height: u32,
    pub note: Option<String>,
}

pub fn optimize(input: &[u8], settings: &Settings) -> Result<Outcome, EngineError> {
    let input_format = format::detect(input);
    let (width, height) = match input_format {
        Format::Svg | Format::Unknown | Format::Heic | Format::Avif => (0, 0),
        _ => decode::dimensions(input).unwrap_or((0, 0)),
    };
    let converting = settings.target != Format::Unknown && settings.target != input_format;

    let (encoded, output_format) = if converting {
        if matches!(input_format, Format::Svg | Format::Heic | Format::Avif | Format::Unknown) {
            // HEIC/AVIF are decoded by the app (ImageIO) and handed over as PNG.
            return Err(EngineError::Unsupported(format!(
                "Can't convert {} to {}",
                input_format.name(),
                settings.target.name()
            )));
        }
        if input_format == Format::Gif && is_animated_gif(input) {
            return Err(EngineError::Unsupported("Animated GIFs can't be converted yet".into()));
        }
        let raster = decode::decode(input)?;
        let bytes = match settings.target {
            Format::WebP => webp_opt::encode(&raster.image, settings.lossless, settings)?,
            Format::Avif => avif::encode(&raster.image, settings)?,
            Format::Jpeg => jpeg::encode(&raster.image, raster.icc.as_deref(), settings)?,
            Format::Png => {
                let mut png = Vec::new();
                raster
                    .image
                    .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
                    .map_err(|e| EngineError::Encode(e.to_string()))?;
                png_opt::optimize(&png, settings)?
            }
            other => return Err(EngineError::Unsupported(format!("Can't encode {}", other.name()))),
        };
        (bytes, settings.target)
    } else {
        let bytes = match input_format {
            Format::Png => png_opt::optimize(input, settings)?,
            Format::Jpeg => jpeg::optimize(input, settings)?,
            Format::WebP => webp_opt::reencode(input, settings)?,
            Format::Svg => svg::optimize(input)?,
            Format::Unknown => return Err(EngineError::Unsupported("Not an image Squish understands".into())),
            other => {
                return Err(EngineError::Unsupported(format!(
                    "{} can only be converted (pick WebP, AVIF or JPEG output)",
                    other.name()
                )));
            }
        };
        (bytes, input_format)
    };

    let note = (converting && encoded.len() >= input.len()).then(|| "Converted file is larger than the original".to_string());
    let data = if converting || encoded.len() < input.len() { Some(encoded) } else { None };
    Ok(Outcome { data, input_format, output_format, width, height, note })
}

fn is_animated_gif(data: &[u8]) -> bool {
    use image::AnimationDecoder;
    image::codecs::gif::GifDecoder::new(std::io::Cursor::new(data))
        .map(|d| d.into_frames().take(2).count() > 1)
        .unwrap_or(false)
}
