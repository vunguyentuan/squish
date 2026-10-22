//! Downscaling to a maximum edge length: Lanczos3 via fast_image_resize (SIMD, alpha-aware).

use fast_image_resize::{FilterType, ResizeAlg, ResizeOptions, Resizer};
use image::DynamicImage;

use crate::engine::EngineError;

/// The size that fits inside `max_edge`, or `None` when the image already fits (or `max_edge` is 0).
pub fn fit(width: u32, height: u32, max_edge: u32) -> Option<(u32, u32)> {
    let longest = width.max(height);
    if max_edge == 0 || longest <= max_edge {
        return None;
    }
    let scale = f64::from(max_edge) / f64::from(longest);
    let side = |v: u32| ((f64::from(v) * scale).round() as u32).clamp(1, max_edge);
    Some((side(width), side(height)))
}

pub fn downscale(image: &DynamicImage, width: u32, height: u32) -> Result<DynamicImage, EngineError> {
    let mut resized = DynamicImage::new(width, height, image.color());
    let options = ResizeOptions::new().resize_alg(ResizeAlg::Convolution(FilterType::Lanczos3));
    Resizer::new()
        .resize(image, &mut resized, &options)
        .map_err(|e| EngineError::Encode(format!("resize: {e}")))?;
    Ok(resized)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fits_the_longest_edge() {
        assert_eq!(fit(4032, 3024, 2560), Some((2560, 1920)));
        assert_eq!(fit(3024, 4032, 2560), Some((1920, 2560)));
        assert_eq!(fit(10_000, 3, 100), Some((100, 1)));
    }

    #[test]
    fn leaves_small_images_alone() {
        assert_eq!(fit(1920, 1080, 2560), None);
        assert_eq!(fit(2560, 1000, 2560), None);
        assert_eq!(fit(8000, 8000, 0), None);
    }

    #[test]
    fn downscales_with_alpha() {
        let image = DynamicImage::new_rgba8(400, 200);
        let small = downscale(&image, 100, 50).unwrap();
        assert_eq!((small.width(), small.height()), (100, 50));
        assert!(small.color().has_alpha());
    }
}
