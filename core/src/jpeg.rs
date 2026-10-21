//! JPEG: mozjpeg in two flavours.
//!
//! * Lossless: jpegtran-style DCT coefficient transcode with optimized Huffman
//!   tables and mozjpeg's progressive scan search. Pixels are untouched.
//! * Lossy: decode and re-encode with trellis quantization. The lossless
//!   transcode is always computed too, and the smaller of the two wins.

use std::ffi::c_ulong;
use std::mem;
use std::os::raw::{c_int, c_uint};
use std::panic::{self, AssertUnwindSafe};
use std::ptr;

use mozjpeg::{ColorSpace, Compress, Decompress, Marker, ScanMode};
use mozjpeg_sys as ffi;

use crate::engine::{EngineError, Settings};
use crate::exif;

const APP0: u8 = 0xE0;
const APP1: u8 = 0xE1;
const APP2: u8 = 0xE2;
const APP14: u8 = 0xEE;
const COM: u8 = 0xFE;

pub fn optimize(data: &[u8], settings: &Settings) -> Result<Vec<u8>, EngineError> {
    if settings.lossless {
        return guarded(|| transcode_lossless(data, settings));
    }
    let lossy = guarded(|| recompress(data, settings));
    // A lossless transcode only trims entropy coding and metadata (typically 5–20%), so it
    // can't beat a re-encode that already halved the file. Skipping it saves ~60% of the time.
    if let Ok(small) = &lossy {
        if small.len() * 2 < data.len() {
            return lossy;
        }
    }
    let lossless = guarded(|| transcode_lossless(data, settings));
    match (lossy, lossless) {
        (Ok(a), Ok(b)) => Ok(if a.len() < b.len() { a } else { b }),
        (Ok(a), Err(_)) => Ok(a),
        (Err(_), Ok(b)) => Ok(b),
        (Err(e), Err(_)) => Err(e),
    }
}

/// Which source markers survive into the output.
struct MarkerPolicy {
    keep_icc: bool,
    keep_metadata: bool,
}

impl MarkerPolicy {
    fn new(settings: &Settings) -> Self {
        Self {
            keep_icc: settings.keep_color_profile || !settings.strip_metadata,
            keep_metadata: !settings.strip_metadata,
        }
    }

    fn keeps(&self, marker: u8, data: &[u8]) -> bool {
        match marker {
            // libjpeg writes fresh JFIF / Adobe headers itself.
            APP0 | APP14 => false,
            APP2 if data.starts_with(b"ICC_PROFILE\0") => self.keep_icc,
            _ => self.keep_metadata,
        }
    }

    /// When metadata is stripped, a tiny EXIF block keeps rotated photos upright.
    fn orientation_marker<'a>(&self, markers: impl Iterator<Item = (u8, &'a [u8])>) -> Option<Vec<u8>> {
        if self.keep_metadata {
            return None;
        }
        markers
            .filter(|(m, _)| *m == APP1)
            .find_map(|(_, d)| exif::orientation(d))
            .filter(|&o| o > 1 && o <= 8)
            .map(exif::minimal_orientation_app1)
    }
}

fn recompress(data: &[u8], settings: &Settings) -> Result<Vec<u8>, EngineError> {
    let policy = MarkerPolicy::new(settings);
    let io = |e: std::io::Error| EngineError::Encode(format!("mozjpeg: {e}"));

    let decoder = Decompress::with_markers(mozjpeg::ALL_MARKERS).from_mem(data).map_err(io)?;
    let markers: Vec<(u8, Vec<u8>)> = decoder
        .markers()
        .map(|m| (c_int::from(m.marker) as u8, m.data.to_vec()))
        .collect();
    let (width, height) = decoder.size();
    let gray = decoder.color_space() == ColorSpace::JCS_GRAYSCALE;
    if matches!(decoder.color_space(), ColorSpace::JCS_CMYK | ColorSpace::JCS_YCCK) {
        return Err(EngineError::Unsupported("CMYK JPEG is kept lossless".into()));
    }

    let (pixels, color_space) = if gray {
        let mut started = decoder.grayscale().map_err(io)?;
        let px = started.read_scanlines::<u8>().map_err(io)?;
        started.finish().map_err(io)?;
        (px, ColorSpace::JCS_GRAYSCALE)
    } else {
        let mut started = decoder.rgb().map_err(io)?;
        let px = started.read_scanlines::<u8>().map_err(io)?;
        started.finish().map_err(io)?;
        (px, ColorSpace::JCS_RGB)
    };

    let extra = markers.iter().filter(|(m, d)| policy.keeps(*m, d)).cloned();
    let orientation = policy.orientation_marker(markers.iter().map(|(m, d)| (*m, d.as_slice())));
    let extra: Vec<(u8, Vec<u8>)> = extra.chain(orientation.map(|o| (APP1, o))).collect();
    compress(&pixels, width, height, color_space, &extra, settings)
}

/// Encodes a decoded raster (alpha is flattened onto white).
pub fn encode(image: &image::DynamicImage, icc: Option<&[u8]>, settings: &Settings) -> Result<Vec<u8>, EngineError> {
    let markers: Vec<(u8, Vec<u8>)> = icc
        .filter(|_| settings.keep_color_profile || !settings.strip_metadata)
        .map(icc_markers)
        .unwrap_or_default();
    let flat = if image.color().has_alpha() {
        let rgba = image.to_rgba8();
        let mut rgb = image::RgbImage::new(rgba.width(), rgba.height());
        for (dst, src) in rgb.pixels_mut().zip(rgba.pixels()) {
            let a = src[3] as u32;
            for c in 0..3 {
                dst[c] = ((src[c] as u32 * a + 255 * (255 - a) + 127) / 255) as u8;
            }
        }
        rgb
    } else {
        image.to_rgb8()
    };
    let (w, h) = flat.dimensions();
    guarded(|| compress(flat.as_raw(), w as usize, h as usize, ColorSpace::JCS_RGB, &markers, settings))
}

/// Splits an ICC profile into APP2 chunks per the ICC.1 embedding spec.
fn icc_markers(icc: &[u8]) -> Vec<(u8, Vec<u8>)> {
    const MAX_DATA: usize = 65_519;
    let count = icc.len().div_ceil(MAX_DATA);
    icc.chunks(MAX_DATA)
        .enumerate()
        .map(|(i, chunk)| {
            let mut payload = b"ICC_PROFILE\0".to_vec();
            payload.extend_from_slice(&[(i + 1) as u8, count as u8]);
            payload.extend_from_slice(chunk);
            (APP2, payload)
        })
        .collect()
}

fn compress(
    pixels: &[u8],
    width: usize,
    height: usize,
    color_space: ColorSpace,
    markers: &[(u8, Vec<u8>)],
    settings: &Settings,
) -> Result<Vec<u8>, EngineError> {
    let io = |e: std::io::Error| EngineError::Encode(format!("mozjpeg: {e}"));
    let mut comp = Compress::new(color_space);
    comp.set_size(width, height);
    comp.set_quality(settings.quality.clamp(1, 100) as f32);
    comp.set_progressive_mode();
    comp.set_scan_optimization_mode(ScanMode::AllComponentsTogether);
    comp.set_optimize_scans(true);
    comp.set_optimize_coding(true);
    if color_space != ColorSpace::JCS_GRAYSCALE {
        // Full-resolution chroma above q90 keeps red text and fine colour edges crisp.
        if settings.quality >= 90 {
            comp.set_chroma_sampling_pixel_sizes((1, 1), (1, 1));
        } else {
            comp.set_chroma_sampling_pixel_sizes((2, 2), (2, 2));
        }
    }

    let mut started = comp.start_compress(Vec::with_capacity(pixels.len() / 8)).map_err(io)?;
    for (marker, payload) in markers {
        started.write_marker(Marker::from(*marker), payload);
    }
    started.write_scanlines(pixels).map_err(io)?;
    started.finish().map_err(io)
}

/// Owns the libjpeg structs so they are destroyed even when an error unwinds.
struct Transcoder {
    err: Box<ffi::jpeg_error_mgr>,
    src: Box<ffi::jpeg_decompress_struct>,
    dst: Box<ffi::jpeg_compress_struct>,
    out_buf: *mut u8,
    out_len: c_ulong,
    src_created: bool,
    dst_created: bool,
}

impl Drop for Transcoder {
    fn drop(&mut self) {
        unsafe {
            if self.dst_created {
                ffi::jpeg_destroy_compress(&mut self.dst);
            }
            if self.src_created {
                ffi::jpeg_destroy_decompress(&mut self.src);
            }
            if !self.out_buf.is_null() {
                libc::free(self.out_buf.cast());
            }
        }
    }
}

fn transcode_lossless(data: &[u8], settings: &Settings) -> Result<Vec<u8>, EngineError> {
    let policy = MarkerPolicy::new(settings);
    unsafe {
        let mut t = Transcoder {
            err: Box::new(mem::zeroed()),
            src: Box::new(mem::zeroed()),
            dst: Box::new(mem::zeroed()),
            out_buf: ptr::null_mut(),
            out_len: 0,
            src_created: false,
            dst_created: false,
        };
        ffi::jpeg_std_error(&mut t.err);
        t.err.error_exit = Some(unwind_error_exit);
        t.err.emit_message = Some(silence_message);

        t.src.common.err = &mut *t.err;
        ffi::jpeg_create_decompress(&mut *t.src);
        t.src_created = true;
        ffi::jpeg_mem_src(&mut t.src, data.as_ptr(), data.len() as c_ulong);
        for n in 1..16 {
            ffi::jpeg_save_markers(&mut t.src, (APP0 + n) as c_int, 0xFFFF);
        }
        ffi::jpeg_save_markers(&mut t.src, COM as c_int, 0xFFFF);
        ffi::jpeg_read_header(&mut t.src, 1);
        let coefficients = ffi::jpeg_read_coefficients(&mut t.src);

        t.dst.common.err = &mut *t.err;
        ffi::jpeg_create_compress(&mut *t.dst);
        t.dst_created = true;
        ffi::jpeg_copy_critical_parameters(&t.src, &mut t.dst);
        t.dst.optimize_coding = 1;
        ffi::jpeg_c_set_bool_param(&mut t.dst, ffi::JBOOLEAN_OPTIMIZE_SCANS, 1);
        ffi::jpeg_simple_progression(&mut t.dst);
        ffi::jpeg_mem_dest(&mut t.dst, &mut t.out_buf, &mut t.out_len);
        ffi::jpeg_write_coefficients(&mut t.dst, coefficients);

        let mut saved = Vec::new();
        let mut node = t.src.marker_list;
        while !node.is_null() {
            let m = &*node;
            saved.push((m.marker, std::slice::from_raw_parts(m.data, m.data_length as usize)));
            node = m.next;
        }
        for (marker, payload) in &saved {
            if policy.keeps(*marker, payload) {
                ffi::jpeg_write_marker(&mut t.dst, *marker as c_int, payload.as_ptr(), payload.len() as c_uint);
            }
        }
        if let Some(app1) = policy.orientation_marker(saved.iter().copied()) {
            ffi::jpeg_write_marker(&mut t.dst, APP1 as c_int, app1.as_ptr(), app1.len() as c_uint);
        }

        ffi::jpeg_finish_compress(&mut t.dst);
        ffi::jpeg_finish_decompress(&mut t.src);
        if t.out_buf.is_null() {
            return Err(EngineError::Encode("mozjpeg produced no output".into()));
        }
        Ok(std::slice::from_raw_parts(t.out_buf, t.out_len as usize).to_vec())
    }
}

/// Runs libjpeg code, turning its unwinding fatal errors into `EngineError`s.
fn guarded<T>(f: impl FnOnce() -> Result<T, EngineError>) -> Result<T, EngineError> {
    match panic::catch_unwind(AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(payload) => {
            let msg = payload
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "libjpeg failed".into());
            Err(EngineError::Decode(msg))
        }
    }
}

unsafe extern "C-unwind" fn unwind_error_exit(cinfo: &mut ffi::jpeg_common_struct) {
    let mut message = String::from("libjpeg: ");
    unsafe {
        if let Some(err) = cinfo.err.as_ref()
            && let Some(format) = err.format_message
        {
            // libjpeg writes into the buffer, so the binding's shared reference must be mutable.
            let format = mem::transmute::<
                unsafe extern "C-unwind" fn(&mut ffi::jpeg_common_struct, &[u8; 80]),
                unsafe extern "C-unwind" fn(&mut ffi::jpeg_common_struct, &mut [u8; 80]),
            >(format);
            let mut buffer = [0u8; 80];
            format(cinfo, &mut buffer);
            let text = buffer.split(|&c| c == 0).next().unwrap_or_default();
            message.push_str(&String::from_utf8_lossy(text));
        }
    }
    panic::resume_unwind(Box::new(message));
}

unsafe extern "C-unwind" fn silence_message(_cinfo: &mut ffi::jpeg_common_struct, _level: c_int) {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::format::Format;

    fn settings(lossless: bool) -> Settings {
        Settings {
            quality: 80,
            lossless,
            strip_metadata: true,
            keep_color_profile: true,
            effort: 1,
            target: Format::Unknown,
        }
    }

    fn sample_jpeg() -> Vec<u8> {
        let img = image::RgbImage::from_fn(317, 211, |x, y| {
            image::Rgb([(x * 7 % 256) as u8, (y * 3 % 256) as u8, ((x ^ y) % 256) as u8])
        });
        let mut s = settings(false);
        s.quality = 95;
        compress(img.as_raw(), 317, 211, ColorSpace::JCS_RGB, &[], &s).unwrap()
    }

    #[test]
    fn lossless_transcode_keeps_pixels() {
        let original = sample_jpeg();
        let optimized = optimize(&original, &settings(true)).unwrap();
        let a = image::load_from_memory(&original).unwrap().to_rgb8();
        let b = image::load_from_memory(&optimized).unwrap().to_rgb8();
        assert_eq!(a.as_raw(), b.as_raw());
    }

    #[test]
    fn corrupt_input_is_an_error_not_a_crash() {
        let mut data = sample_jpeg();
        data.truncate(data.len() / 3);
        data[200..400].fill(0xFF);
        let _ = optimize(&data, &settings(false));
        assert!(optimize(b"\xFF\xD8\xFFnope", &settings(true)).is_err());
    }

    #[test]
    fn keeps_orientation_when_stripping() {
        let original = sample_jpeg();
        // Splice an orientation=6 EXIF block right after SOI.
        let app1 = exif::minimal_orientation_app1(6);
        let mut tagged = original[..2].to_vec();
        tagged.extend_from_slice(&[0xFF, APP1]);
        tagged.extend_from_slice(&((app1.len() + 2) as u16).to_be_bytes());
        tagged.extend_from_slice(&app1);
        tagged.extend_from_slice(&original[2..]);
        for lossless in [true, false] {
            let out = optimize(&tagged, &settings(lossless)).unwrap();
            let pos = out.windows(6).position(|w| w == b"Exif\0\0").expect("EXIF kept");
            assert_eq!(exif::orientation(&out[pos..]), Some(6));
        }
    }
}
