//! Command-line harness: `cargo run --release --example squish -- [-q 80] [-l] [-e 1] [-f webp] files…`

use std::ffi::{CStr, CString};

use squish_core::{SquishOptions, squish_optimize_file, squish_result_free};

fn main() {
    let mut opts = SquishOptions {
        quality: 80,
        lossless: false,
        strip_metadata: true,
        keep_color_profile: true,
        effort: 1,
        output_format: 0,
        max_dimension: 0,
    };
    let mut files = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "-q" => opts.quality = args.next().unwrap().parse().unwrap(),
            "-e" => opts.effort = args.next().unwrap().parse().unwrap(),
            "-l" => opts.lossless = true,
            "-f" => {
                opts.output_format = match args.next().unwrap().as_str() {
                    "png" => 1,
                    "jpeg" | "jpg" => 2,
                    "webp" => 3,
                    "avif" => 4,
                    _ => 0,
                }
            }
            _ => files.push(a),
        }
    }
    let ext = ["", "png", "jpg", "webp", "avif"][opts.output_format as usize];
    for f in files {
        let out_ext = if ext.is_empty() { f.rsplit('.').next().unwrap().to_string() } else { ext.to_string() };
        let out = format!("{}.out.{out_ext}", f.rsplit_once('.').map(|(a, _)| a).unwrap_or(&f));
        let (cin, cout) = (CString::new(f.clone()).unwrap(), CString::new(out.clone()).unwrap());
        let mut r = unsafe { squish_optimize_file(cin.as_ptr(), cout.as_ptr(), &opts) };
        let msg = if r.message.is_null() { String::new() } else { unsafe { CStr::from_ptr(r.message) }.to_string_lossy().into() };
        let saved = 100.0 * (1.0 - r.optimized_size as f64 / r.original_size.max(1) as f64);
        println!(
            "{f:<28} status {:>2}  {:>9} -> {:>9}  {saved:>6.1}%  {}x{}  {:>6} ms  {msg}",
            r.status, r.original_size, r.optimized_size, r.width, r.height, r.elapsed_ms
        );
        unsafe { squish_result_free(&mut r) };
    }
}
