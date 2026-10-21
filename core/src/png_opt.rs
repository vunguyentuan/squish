//! PNG: libimagequant palette quantization (lossy) followed by oxipng (lossless).

use std::num::NonZeroU64;
use std::time::Duration;

use oxipng::{Deflater, Options, StripChunks, ZopfliOptions};

use crate::decode;
use crate::engine::{EngineError, Settings};
use crate::format;

pub fn optimize(data: &[u8], settings: &Settings) -> Result<Vec<u8>, EngineError> {
    let oxi = oxipng_options(settings);
    if settings.lossless || format::is_animated_png(data) {
        return run_oxipng(data, &oxi);
    }
    match quantize(data, settings)? {
        Some(palette_png) => {
            let lossy = run_oxipng(&palette_png, &oxi)?;
            // Already-paletted images can come back larger; never lose to plain lossless.
            if lossy.len() as f64 > data.len() as f64 * 0.9 {
                let lossless = run_oxipng(data, &oxi)?;
                if lossless.len() <= lossy.len() {
                    return Ok(lossless);
                }
            }
            Ok(lossy)
        }
        None => run_oxipng(data, &oxi),
    }
}

/// Lossless re-encode of freshly produced PNG bytes (used by other pipelines).
pub fn run_oxipng(data: &[u8], opts: &Options) -> Result<Vec<u8>, EngineError> {
    oxipng::optimize_from_memory(data, opts).map_err(|e| EngineError::Encode(format!("oxipng: {e}")))
}

pub fn oxipng_options(settings: &Settings) -> Options {
    let mut opts = match settings.effort {
        0 => Options::from_preset(2),
        1 => {
            // Preset 4's filter search with libdeflate level 11 instead of 12:
            // 25–40% faster for files within ~1% of the size.
            let mut o = Options::from_preset(4);
            o.deflater = Deflater::Libdeflater { compression: 11 };
            o
        }
        _ => {
            let mut o = Options::from_preset(6);
            o.deflater = Deflater::Zopfli(ZopfliOptions {
                iteration_count: NonZeroU64::new(15).unwrap(),
                ..Default::default()
            });
            o.timeout = Some(Duration::from_secs(120));
            o
        }
    };
    opts.strip = if settings.strip_metadata { StripChunks::Safe } else { StripChunks::None };
    if settings.strip_metadata && !settings.keep_color_profile {
        opts.strip = StripChunks::Strip(oxipng::indexset! { *b"iCCP" });
    }
    // Rewriting the colour of fully transparent pixels is invisible but not bit-exact.
    opts.optimize_alpha = !settings.lossless;
    opts.fix_errors = true;
    opts
}

/// Returns `None` when libimagequant cannot hit the minimum quality.
fn quantize(data: &[u8], settings: &Settings) -> Result<Option<Vec<u8>>, EngineError> {
    let raster = decode::decode(data)?;
    let rgba = raster.image.to_rgba8();
    let (width, height) = rgba.dimensions();
    let pixels: Vec<imagequant::RGBA> = rgba
        .as_raw()
        .chunks_exact(4)
        .map(|p| imagequant::RGBA::new(p[0], p[1], p[2], p[3]))
        .collect();

    let quant_err = |e: imagequant::Error| EngineError::Encode(format!("libimagequant: {e}"));
    let mut attr = imagequant::new();
    attr.set_speed(match settings.effort {
        0 => 8,
        1 => 4,
        _ => 1,
    })
    .map_err(quant_err)?;
    let target = settings.quality.clamp(1, 100);
    attr.set_quality(target.saturating_sub(20), target).map_err(quant_err)?;

    let mut image = attr.new_image(pixels, width as usize, height as usize, 0.0).map_err(quant_err)?;
    let mut result = match attr.quantize(&mut image) {
        Ok(r) => r,
        Err(imagequant::Error::QualityTooLow) => return Ok(None),
        Err(e) => return Err(quant_err(e)),
    };
    result.set_dithering_level(1.0).map_err(quant_err)?;
    let (palette, indices) = result.remapped(&mut image).map_err(quant_err)?;

    let mut info = png::Info::with_size(width, height);
    info.color_type = png::ColorType::Indexed;
    info.bit_depth = png::BitDepth::Eight;
    info.palette = Some(palette.iter().flat_map(|c| [c.r, c.g, c.b]).collect::<Vec<_>>().into());
    let mut trns: Vec<u8> = palette.iter().map(|c| c.a).collect();
    while trns.last() == Some(&255) {
        trns.pop();
    }
    if !trns.is_empty() {
        info.trns = Some(trns.into());
    }
    if settings.keep_color_profile || !settings.strip_metadata {
        info.icc_profile = raster.icc.map(Into::into);
    }

    let mut out = Vec::with_capacity(indices.len() / 2);
    {
        let png_err = |e: png::EncodingError| EngineError::Encode(format!("png: {e}"));
        let mut encoder = png::Encoder::with_info(&mut out, info).map_err(png_err)?;
        encoder.set_compression(png::Compression::Fast);
        let mut writer = encoder.write_header().map_err(png_err)?;
        writer.write_image_data(&indices).map_err(png_err)?;
        writer.finish().map_err(png_err)?;
    }
    Ok(Some(out))
}
