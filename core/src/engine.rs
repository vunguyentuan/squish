//! Format dispatch and the "never make a file bigger" rule.

use crate::format::{self, Format};
use crate::{anim, avif, decode, jpeg, png_opt, resize, svg, webp_opt};

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
    /// Longest edge in pixels; larger images are downscaled. 0 keeps the size.
    pub max_dimension: u32,
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
    if input_format == Format::Gif && is_animated_gif(input) {
        return animated_gif(input, settings);
    }
    let target = if settings.target == Format::Unknown { input_format } else { settings.target };
    let converting = target != input_format;
    // Animations would lose every frame but the first, so they keep their size.
    let animated = format::is_animated_png(input) || format::is_animated_webp(input);
    let resize_to = (!animated && is_encodable(target))
        .then(|| resize::fit(width, height, settings.max_dimension))
        .flatten();

    let (encoded, output_format, (width, height)) = if converting || resize_to.is_some() {
        if matches!(input_format, Format::Svg | Format::Heic | Format::Avif | Format::Unknown) {
            // HEIC/AVIF are decoded by the app (ImageIO) and handed over as PNG.
            return Err(EngineError::Unsupported(format!(
                "Can't convert {} to {}",
                input_format.name(),
                target.name()
            )));
        }
        let mut raster = decode::decode(input)?;
        if let Some((w, h)) = resize_to {
            raster.image = resize::downscale(&raster.image, w, h)?;
        }
        let size = (raster.image.width(), raster.image.height());
        (encode_raster(&raster, target, settings)?, target, size)
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
        (bytes, input_format, (width, height))
    };

    // A resized or converted file is what was asked for, even in the rare case it grew.
    let reshaped = converting || resize_to.is_some();
    let note = (reshaped && encoded.len() >= input.len()).then(|| {
        if converting { "Converted file is larger than the original" } else { "Resized file is larger than the original" }.to_string()
    });
    let data = if reshaped || encoded.len() < input.len() { Some(encoded) } else { None };
    Ok(Outcome { data, input_format, output_format, width, height, note })
}

fn is_encodable(format: Format) -> bool {
    matches!(format, Format::Png | Format::Jpeg | Format::WebP | Format::Avif)
}

fn encode_raster(raster: &decode::Raster, target: Format, settings: &Settings) -> Result<Vec<u8>, EngineError> {
    match target {
        Format::WebP => webp_opt::encode(&raster.image, settings.lossless, settings),
        Format::Avif => avif::encode(&raster.image, settings),
        Format::Jpeg => jpeg::encode(&raster.image, raster.icc.as_deref(), settings),
        Format::Png => {
            let mut png = Vec::new();
            raster
                .image
                .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
                .map_err(|e| EngineError::Encode(e.to_string()))?;
            png_opt::optimize(&png, settings)
        }
        other => Err(EngineError::Unsupported(format!("Can't encode {}", other.name()))),
    }
}

/// Animated GIFs become animated WebP; the app turns them into MP4 itself.
fn animated_gif(input: &[u8], settings: &Settings) -> Result<Outcome, EngineError> {
    if settings.target != Format::WebP {
        return Err(EngineError::Unsupported("Animated GIFs can only be converted to WebP or MP4".into()));
    }
    let animation = anim::gif_to_webp(input, settings)?;
    let note = (animation.data.len() >= input.len()).then(|| "Converted file is larger than the original".to_string());
    Ok(Outcome {
        data: Some(animation.data),
        input_format: Format::Gif,
        output_format: Format::WebP,
        width: animation.width,
        height: animation.height,
        note,
    })
}

fn is_animated_gif(data: &[u8]) -> bool {
    use image::AnimationDecoder;
    image::codecs::gif::GifDecoder::new(std::io::Cursor::new(data))
        .map(|d| d.into_frames().take(2).count() > 1)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};

    fn settings() -> Settings {
        Settings {
            quality: 80,
            lossless: false,
            strip_metadata: true,
            keep_color_profile: true,
            effort: 0,
            target: Format::Unknown,
            max_dimension: 0,
        }
    }

    fn encoded(width: u32, height: u32, format: ImageFormat) -> Vec<u8> {
        let image = RgbaImage::from_fn(width, height, |x, y| Rgba([(x % 251) as u8, (y % 241) as u8, ((x + y) % 239) as u8, 255]));
        let image = if format == ImageFormat::Jpeg {
            DynamicImage::ImageRgb8(DynamicImage::ImageRgba8(image).to_rgb8())
        } else {
            DynamicImage::ImageRgba8(image)
        };
        let mut out = Vec::new();
        image.write_to(&mut std::io::Cursor::new(&mut out), format).unwrap();
        out
    }

    #[test]
    fn resizes_in_the_source_format() {
        for (format, expected) in [(ImageFormat::Png, Format::Png), (ImageFormat::Jpeg, Format::Jpeg)] {
            let input = encoded(800, 400, format);
            let outcome = optimize(&input, &Settings { max_dimension: 200, ..settings() }).unwrap();
            assert_eq!((outcome.width, outcome.height), (200, 100));
            assert_eq!(outcome.output_format, expected);
            let data = outcome.data.expect("a resized file is always written");
            assert_eq!(decode::dimensions(&data), Some((200, 100)));
        }
    }

    #[test]
    fn resizes_while_converting() {
        let input = encoded(600, 900, ImageFormat::Png);
        let settings = Settings { max_dimension: 300, target: Format::WebP, ..settings() };
        let outcome = optimize(&input, &settings).unwrap();
        assert_eq!(outcome.output_format, Format::WebP);
        assert_eq!((outcome.width, outcome.height), (200, 300));
    }

    #[test]
    fn small_images_skip_the_resize() {
        let input = encoded(120, 80, ImageFormat::Png);
        let outcome = optimize(&input, &Settings { max_dimension: 2560, ..settings() }).unwrap();
        assert_eq!((outcome.width, outcome.height), (120, 80));
    }

    #[test]
    fn animated_gif_needs_webp_target() {
        use image::codecs::gif::GifEncoder;
        use image::{Delay, Frame};
        let mut gif = Vec::new();
        {
            let mut encoder = GifEncoder::new(&mut gif);
            for i in 0..3u8 {
                let frame = RgbaImage::from_pixel(40, 30, Rgba([i * 80, 20, 200, 255]));
                encoder.encode_frame(Frame::from_parts(frame, 0, 0, Delay::from_numer_denom_ms(50, 1))).unwrap();
            }
        }
        assert!(matches!(optimize(&gif, &settings()), Err(EngineError::Unsupported(_))));
        let outcome = optimize(&gif, &Settings { target: Format::WebP, ..settings() }).unwrap();
        assert_eq!(outcome.output_format, Format::WebP);
        assert!(format::is_animated_webp(outcome.data.as_deref().unwrap()));
    }
}
