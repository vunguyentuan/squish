//! Standalone build of the `squish` CLI (the app bundle runs the same code from its own binary).

fn main() -> std::process::ExitCode {
    std::process::ExitCode::from(squish_core::cli::run(std::env::args().skip(1)) as u8)
}
