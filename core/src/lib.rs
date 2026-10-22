//! Squish core: the image optimization engine behind the macOS app, exposed over a C ABI.
//!
//! Every entry point is panic-safe: codec failures come back as status codes, never aborts.

mod avif;
mod decode;
mod engine;
mod exif;
mod format;
mod jpeg;
mod png_opt;
mod resize;
mod svg;
mod webp_opt;

use std::ffi::{CStr, CString, c_char};
use std::panic::{self, AssertUnwindSafe};
use std::path::Path;
use std::time::Instant;

pub use engine::{EngineError, Settings};
pub use format::Format;

pub const SQUISH_OK: i32 = 0;
pub const SQUISH_ALREADY_OPTIMAL: i32 = 1;
pub const SQUISH_ERR_IO: i32 = -1;
pub const SQUISH_ERR_UNSUPPORTED: i32 = -2;
pub const SQUISH_ERR_DECODE: i32 = -3;
pub const SQUISH_ERR_ENCODE: i32 = -4;
pub const SQUISH_ERR_INTERNAL: i32 = -5;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SquishOptions {
    /// Target quality for lossy encoders, 1...100.
    pub quality: u8,
    /// Only bit-exact (pixel-identical) transformations.
    pub lossless: bool,
    pub strip_metadata: bool,
    /// Keep ICC profiles even when stripping metadata.
    pub keep_color_profile: bool,
    /// 0 = fast, 1 = balanced, 2 = maximum.
    pub effort: u8,
    /// A `SquishFormat`; 0 keeps the source format.
    pub output_format: u8,
    /// Longest edge in pixels; larger images are downscaled. 0 keeps the size.
    pub max_dimension: u32,
}

#[repr(C)]
pub struct SquishResult {
    pub status: i32,
    pub input_format: u8,
    pub output_format: u8,
    pub width: u32,
    pub height: u32,
    pub original_size: u64,
    /// Size of the written file, or `original_size` when nothing was written.
    pub optimized_size: u64,
    pub elapsed_ms: u64,
    /// Human-readable detail; may be NULL. Release with `squish_result_free`.
    pub message: *mut c_char,
}

impl SquishResult {
    fn failure(status: i32, message: &str) -> Self {
        Self {
            status,
            input_format: 0,
            output_format: 0,
            width: 0,
            height: 0,
            original_size: 0,
            optimized_size: 0,
            elapsed_ms: 0,
            message: to_c(message),
        }
    }
}

fn to_c(s: &str) -> *mut c_char {
    CString::new(s.replace('\0', " ")).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// Optimizes `input_path` and writes the result to `output_path` only when it is
/// smaller (or when converting formats). The input file is never modified.
///
/// # Safety
/// Paths must be valid NUL-terminated UTF-8 strings and `options` a valid pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn squish_optimize_file(
    input_path: *const c_char,
    output_path: *const c_char,
    options: *const SquishOptions,
) -> SquishResult {
    if input_path.is_null() || output_path.is_null() || options.is_null() {
        return SquishResult::failure(SQUISH_ERR_INTERNAL, "null argument");
    }
    let (input, output, options) = unsafe {
        (
            CStr::from_ptr(input_path).to_string_lossy().into_owned(),
            CStr::from_ptr(output_path).to_string_lossy().into_owned(),
            *options,
        )
    };
    match panic::catch_unwind(AssertUnwindSafe(|| run(&input, &output, &options))) {
        Ok(result) => result,
        Err(_) => SquishResult::failure(SQUISH_ERR_INTERNAL, "The optimizer crashed on this file"),
    }
}

fn run(input: &str, output: &str, options: &SquishOptions) -> SquishResult {
    let started = Instant::now();
    let data = match std::fs::read(input) {
        Ok(d) => d,
        Err(e) => return SquishResult::failure(SQUISH_ERR_IO, &e.to_string()),
    };
    let settings = Settings {
        quality: options.quality.clamp(1, 100),
        lossless: options.lossless,
        strip_metadata: options.strip_metadata,
        keep_color_profile: options.keep_color_profile,
        effort: options.effort.min(2),
        target: Format::from_u8(options.output_format),
        max_dimension: options.max_dimension,
    };
    let original_size = data.len() as u64;

    let mut result = match engine::optimize(&data, &settings) {
        Ok(outcome) => {
            let mut status = SQUISH_ALREADY_OPTIMAL;
            let mut optimized_size = original_size;
            if let Some(bytes) = outcome.data {
                if let Err(e) = write_atomically(Path::new(output), &bytes) {
                    return SquishResult::failure(SQUISH_ERR_IO, &e.to_string());
                }
                status = SQUISH_OK;
                optimized_size = bytes.len() as u64;
            }
            SquishResult {
                status,
                input_format: outcome.input_format as u8,
                output_format: outcome.output_format as u8,
                width: outcome.width,
                height: outcome.height,
                original_size,
                optimized_size,
                elapsed_ms: 0,
                message: outcome.note.as_deref().map(to_c).unwrap_or(std::ptr::null_mut()),
            }
        }
        Err(err) => {
            let status = match err {
                EngineError::Io(_) => SQUISH_ERR_IO,
                EngineError::Unsupported(_) => SQUISH_ERR_UNSUPPORTED,
                EngineError::Decode(_) => SQUISH_ERR_DECODE,
                EngineError::Encode(_) => SQUISH_ERR_ENCODE,
            };
            let mut r = SquishResult::failure(status, err.message());
            r.input_format = format::detect(&data) as u8;
            r.original_size = original_size;
            r.optimized_size = original_size;
            r
        }
    };
    result.elapsed_ms = started.elapsed().as_millis() as u64;
    result
}

fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension(format!(
        "{}.squish-partial",
        path.extension().and_then(|e| e.to_str()).unwrap_or("")
    ));
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

/// Releases strings owned by a `SquishResult`.
///
/// # Safety
/// `result` must point to a result returned by this library, freed at most once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn squish_result_free(result: *mut SquishResult) {
    if let Some(r) = unsafe { result.as_mut() }
        && !r.message.is_null()
    {
        drop(unsafe { CString::from_raw(r.message) });
        r.message = std::ptr::null_mut();
    }
}

/// Sniffs a file's real format from its header bytes.
///
/// # Safety
/// `path` must be a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn squish_detect_format(path: *const c_char) -> u8 {
    if path.is_null() {
        return 0;
    }
    let path = unsafe { CStr::from_ptr(path) }.to_string_lossy().into_owned();
    let mut head = [0u8; 4096];
    let Ok(mut file) = std::fs::File::open(path) else { return 0 };
    let n = std::io::Read::read(&mut file, &mut head).unwrap_or(0);
    format::detect(&head[..n]) as u8
}

/// Static, NUL-terminated description of the bundled codecs.
#[unsafe(no_mangle)]
pub extern "C" fn squish_engine_info() -> *const c_char {
    c"oxipng 10 · libimagequant 4 · mozjpeg 4 · libwebp · rav1e (ravif) · OXVG · fast_image_resize".as_ptr()
}

/// Static, NUL-terminated engine version.
#[unsafe(no_mangle)]
pub extern "C" fn squish_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}
