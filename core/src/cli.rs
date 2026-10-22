//! `squish`: the Squish engine on the command line.
//!
//! Images only; HEIC/AVIF decoding and video re-encoding live in the macOS app. The app binary
//! doubles as this tool when it is run as `squish` (see `squish_cli_main`), so the engine ships once.

use std::ffi::{CStr, c_char, c_int};
use std::io::{IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::{Format, Report, SQUISH_ALREADY_OPTIMAL, SQUISH_ERR_UNSUPPORTED, SQUISH_OK, SquishOptions, optimize_file};

const USAGE: &str = "\
Usage: squish [options] <files or folders>...

Optimizes PNG, JPEG, WebP, SVG and GIF files (and converts TIFF/BMP) with the Squish engine.
A file is never made bigger. By default results are written next to each original as
<name>-squished.<ext>; converted files get the new extension instead.

Options:
  -q, --quality <1-100>    Quality for lossy encoders (default 80)
  -l, --lossless           Only pixel-identical optimizations
  -e, --effort <level>     fast | balanced | max (default balanced)
  -f, --format <format>    keep | webp | avif | jpeg | png (default keep)
  -r, --resize <pixels>    Downscale so the longest edge is at most <pixels>
  -i, --in-place           Replace originals (only when the result is smaller)
  -o, --out <dir>          Write results into <dir>
  -s, --suffix <text>      Suffix for copies (default -squished)
      --keep-metadata      Keep EXIF, XMP and comments
      --strip-icc          Drop ICC color profiles too
  -n, --dry-run            Report savings without writing anything
      --json               Print one JSON object per file
  -j, --jobs <n>           Files to process in parallel
  -h, --help               Show this help
  -V, --version            Show the engine version
";

const EXTENSIONS: [&str; 10] = ["png", "jpg", "jpeg", "jpe", "webp", "svg", "gif", "tif", "tiff", "bmp"];

struct Config {
    options: SquishOptions,
    in_place: bool,
    out_dir: Option<PathBuf>,
    suffix: String,
    dry_run: bool,
    json: bool,
    jobs: usize,
    inputs: Vec<PathBuf>,
}

/// Runs the CLI with `argv` (program name first) and returns the process exit code.
///
/// # Safety
/// `argv` must hold `argc` valid NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn squish_cli_main(argc: c_int, argv: *const *const c_char) -> c_int {
    let args: Vec<String> = (1..argc.max(0) as usize)
        .map(|i| unsafe { CStr::from_ptr(*argv.add(i)) }.to_string_lossy().into_owned())
        .collect();
    let code = run(args);
    let _ = std::io::stdout().flush();
    code
}

/// Runs the CLI with the arguments after the program name.
pub fn run(args: impl IntoIterator<Item = String>) -> i32 {
    let config = match parse(args.into_iter()) {
        Ok(Some(c)) => c,
        Ok(None) => return 0,
        Err(message) => {
            eprintln!("squish: {message}\n\n{USAGE}");
            return 2;
        }
    };

    let files = collect(&config.inputs, &config.suffix);
    if files.is_empty() {
        eprintln!("squish: no images found");
        return 2;
    }
    if let Some(dir) = &config.out_dir
        && let Err(e) = std::fs::create_dir_all(dir)
    {
        eprintln!("squish: can't create {}: {e}", dir.display());
        return 1;
    }

    let next = AtomicUsize::new(0);
    let totals = Mutex::new(Totals::default());
    let workers = config.jobs.clamp(1, files.len());
    std::thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| {
                while let Some(file) = files.get(next.fetch_add(1, Ordering::Relaxed)) {
                    let report = process(file, &config);
                    let mut totals = totals.lock().unwrap();
                    totals.add(&report);
                    print_report(file, &report, &config);
                }
            });
        }
    });

    let totals = totals.into_inner().unwrap();
    if !config.json && files.len() > 1 {
        let verb = if config.dry_run { "Would save" } else { "Saved" };
        println!(
            "\n{} files · {} {} ({}) · {} failed",
            files.len(),
            verb,
            bytes(totals.saved()),
            percent(totals.saved(), totals.original),
            totals.failed
        );
    }
    if totals.failed > 0 { 1 } else { 0 }
}

fn parse(mut args: impl Iterator<Item = String>) -> Result<Option<Config>, String> {
    let mut config = Config {
        options: SquishOptions {
            quality: 80,
            lossless: false,
            strip_metadata: true,
            keep_color_profile: true,
            effort: 1,
            output_format: 0,
            max_dimension: 0,
        },
        in_place: false,
        out_dir: None,
        suffix: "-squished".into(),
        dry_run: false,
        json: false,
        jobs: std::thread::available_parallelism().map_or(4, |n| (n.get() * 2 / 3).max(2)),
        inputs: Vec::new(),
    };
    while let Some(arg) = args.next() {
        // Accept --flag=value as well as --flag value.
        let (flag, inline) = match arg.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f.to_string(), Some(v.to_string())),
            _ => (arg.clone(), None),
        };
        let take = |args: &mut dyn Iterator<Item = String>| match &inline {
            Some(v) => Ok(v.clone()),
            None => args.next().ok_or_else(|| format!("{flag} needs a value")),
        };
        match flag.as_str() {
            "-h" | "--help" => {
                print!("{USAGE}");
                return Ok(None);
            }
            "-V" | "--version" => {
                println!("squish {} ({})", env!("CARGO_PKG_VERSION"), engine_info());
                return Ok(None);
            }
            "-q" | "--quality" => {
                let q: u8 = take(&mut args)?.parse().map_err(|_| "quality must be 1-100")?;
                if !(1..=100).contains(&q) {
                    return Err("quality must be 1-100".into());
                }
                config.options.quality = q;
            }
            "-l" | "--lossless" => config.options.lossless = true,
            "-e" | "--effort" => {
                config.options.effort = match take(&mut args)?.as_str() {
                    "0" | "fast" => 0,
                    "1" | "balanced" => 1,
                    "2" | "max" | "maximum" => 2,
                    other => return Err(format!("unknown effort '{other}'")),
                }
            }
            "-f" | "--format" => {
                config.options.output_format = match take(&mut args)?.to_lowercase().as_str() {
                    "keep" | "original" => Format::Unknown,
                    "webp" => Format::WebP,
                    "avif" => Format::Avif,
                    "jpeg" | "jpg" => Format::Jpeg,
                    "png" => Format::Png,
                    other => return Err(format!("unknown format '{other}'")),
                } as u8
            }
            "-r" | "--resize" => {
                config.options.max_dimension = take(&mut args)?.parse().map_err(|_| "resize needs a pixel count")?;
            }
            "-i" | "--in-place" => config.in_place = true,
            "-o" | "--out" => config.out_dir = Some(PathBuf::from(take(&mut args)?)),
            "-s" | "--suffix" => config.suffix = take(&mut args)?,
            "--keep-metadata" => config.options.strip_metadata = false,
            "--strip-icc" => config.options.keep_color_profile = false,
            "-n" | "--dry-run" => config.dry_run = true,
            "--json" => config.json = true,
            "-j" | "--jobs" => config.jobs = take(&mut args)?.parse().map_err(|_| "jobs must be a number")?,
            "--" => config.inputs.extend(args.by_ref().map(PathBuf::from)),
            f if f.starts_with('-') && f.len() > 1 => return Err(format!("unknown option '{f}'")),
            _ => config.inputs.push(PathBuf::from(arg)),
        }
    }
    if config.inputs.is_empty() {
        return Err("no files given".into());
    }
    if config.in_place && config.out_dir.is_some() {
        return Err("--in-place and --out can't be combined".into());
    }
    Ok(Some(config))
}

fn engine_info() -> String {
    unsafe { CStr::from_ptr(crate::squish_engine_info()) }.to_string_lossy().into_owned()
}

/// Expands folders recursively, skipping hidden files and earlier `-squished` copies.
fn collect(inputs: &[PathBuf], suffix: &str) -> Vec<PathBuf> {
    fn walk(dir: &Path, suffix: &str, found: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        let mut entries: Vec<_> = entries.flatten().map(|e| e.path()).collect();
        entries.sort();
        for path in entries {
            if path.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.')) {
                continue;
            }
            let ours = !suffix.is_empty() && path.file_stem().is_some_and(|s| s.to_string_lossy().ends_with(suffix));
            if path.is_dir() {
                walk(&path, suffix, found);
            } else if accepted(&path) && !ours {
                found.push(path);
            }
        }
    }
    let mut found = Vec::new();
    for input in inputs {
        if input.is_dir() {
            walk(input, suffix, &mut found);
        } else if input.exists() {
            // Named explicitly: let the engine decide by content, whatever the extension.
            found.push(input.clone());
        } else {
            eprintln!("squish: {}: no such file", input.display());
        }
    }
    found
}

fn accepted(path: &Path) -> bool {
    path.extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .is_some_and(|e| EXTENSIONS.contains(&e.as_str()))
}

fn process(file: &Path, config: &Config) -> Report {
    let target = Format::from_u8(config.options.output_format);
    let source_ext = file.extension().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default();
    let converting = target != Format::Unknown && !extension_matches(&source_ext, target);
    let output = if config.dry_run {
        std::env::temp_dir().join(format!("squish-cli-{}-{}", std::process::id(), unique()))
    } else {
        destination(file, config, converting, target, &source_ext)
    };
    let report = optimize_file(file, &output, &config.options);
    if config.dry_run {
        let _ = std::fs::remove_file(&output);
    }
    report
}

fn destination(file: &Path, config: &Config, converting: bool, target: Format, source_ext: &str) -> PathBuf {
    let ext = if converting { extension(target) } else { source_ext };
    if config.in_place && !converting {
        return file.to_path_buf();
    }
    let stem = file.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let dir = config.out_dir.clone().unwrap_or_else(|| file.parent().unwrap_or(Path::new(".")).to_path_buf());
    let name = if converting || config.out_dir.is_some() { stem } else { stem + &config.suffix };
    dir.join(if ext.is_empty() { name } else { format!("{name}.{ext}") })
}

fn extension(format: Format) -> &'static str {
    match format {
        Format::Jpeg => "jpg",
        Format::Png => "png",
        Format::WebP => "webp",
        Format::Avif => "avif",
        _ => "",
    }
}

fn extension_matches(ext: &str, format: Format) -> bool {
    let ext = ext.to_lowercase();
    match format {
        Format::Jpeg => matches!(ext.as_str(), "jpg" | "jpeg" | "jpe"),
        other => ext == extension(other),
    }
}

fn unique() -> usize {
    static COUNTER: AtomicUsize = AtomicUsize::new(0);
    COUNTER.fetch_add(1, Ordering::Relaxed)
}

#[derive(Default)]
struct Totals {
    original: u64,
    optimized: u64,
    failed: usize,
}

impl Totals {
    fn add(&mut self, r: &Report) {
        if r.status == SQUISH_OK || r.status == SQUISH_ALREADY_OPTIMAL {
            self.original += r.original_size;
            self.optimized += r.optimized_size;
        } else {
            self.failed += 1;
        }
    }

    fn saved(&self) -> i64 {
        self.original as i64 - self.optimized as i64
    }
}

fn print_report(file: &Path, r: &Report, config: &Config) {
    let mut out = std::io::stdout().lock();
    if config.json {
        let _ = writeln!(
            out,
            "{{\"file\":{},\"status\":\"{}\",\"input_format\":\"{}\",\"output_format\":\"{}\",\"width\":{},\"height\":{},\"original_size\":{},\"optimized_size\":{},\"elapsed_ms\":{},\"message\":{}}}",
            json_string(&file.to_string_lossy()),
            status_name(r.status),
            r.input_format.name(),
            r.output_format.name(),
            r.width,
            r.height,
            r.original_size,
            r.optimized_size,
            r.elapsed_ms,
            r.message.as_deref().map_or("null".into(), json_string),
        );
        return;
    }
    let color = std::io::stdout().is_terminal();
    let paint = |code: &str, text: String| if color { format!("\x1b[{code}m{text}\x1b[0m") } else { text };
    let name = file.display();
    let line = match r.status {
        SQUISH_OK => {
            let saved = r.original_size as i64 - r.optimized_size as i64;
            let summary = format!(
                "{} → {}  {}",
                bytes(r.original_size as i64),
                bytes(r.optimized_size as i64),
                percent(saved, r.original_size)
            );
            format!("{} {name}  {}", paint("32", "✓".into()), paint(if saved >= 0 { "32" } else { "33" }, summary))
        }
        SQUISH_ALREADY_OPTIMAL => format!("{} {name}  {}", paint("2", "·".into()), paint("2", "already optimal".into())),
        _ => format!(
            "{} {name}  {}",
            paint("31", "✗".into()),
            r.message.clone().unwrap_or_else(|| "failed".into())
        ),
    };
    let note = match (&r.message, r.status) {
        (Some(m), SQUISH_OK) => format!("  ({m})"),
        _ => String::new(),
    };
    let _ = writeln!(out, "{line}{note}");
}

fn status_name(status: i32) -> &'static str {
    match status {
        SQUISH_OK => "optimized",
        SQUISH_ALREADY_OPTIMAL => "already_optimal",
        SQUISH_ERR_UNSUPPORTED => "unsupported",
        _ => "failed",
    }
}

fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn bytes(n: i64) -> String {
    let sign = if n < 0 { "-" } else { "" };
    let n = n.unsigned_abs() as f64;
    match n {
        n if n >= 1e9 => format!("{sign}{:.2} GB", n / 1e9),
        n if n >= 1e6 => format!("{sign}{:.1} MB", n / 1e6),
        n if n >= 1e3 => format!("{sign}{:.0} KB", n / 1e3),
        n => format!("{sign}{n} B"),
    }
}

fn percent(saved: i64, original: u64) -> String {
    let p = if original == 0 { 0.0 } else { saved as f64 * 100.0 / original as f64 };
    if p >= 0.0 { format!("{p:.1}% smaller") } else { format!("{:.1}% larger", -p) }
}
