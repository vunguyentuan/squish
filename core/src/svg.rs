//! SVG via OXVG, a Rust port of SVGO's default preset.

use oxvg_ast::parse::roxmltree::parse_with_options;
use oxvg_ast::serialize::Node as _;
use oxvg_ast::visitor::Info;
use oxvg_optimiser::Jobs;
use roxmltree::ParsingOptions;

use crate::engine::EngineError;

pub fn optimize(data: &[u8]) -> Result<Vec<u8>, EngineError> {
    let text = std::str::from_utf8(data).map_err(|_| EngineError::Decode("SVG is not valid UTF-8".into()))?;
    let text = text.trim_start_matches('\u{feff}');
    let options = ParsingOptions { allow_dtd: true, ..Default::default() };
    let output = parse_with_options(text, options, |dom, allocator| {
        Jobs::default().run(dom, &Info::new(allocator)).map_err(|e| e.to_string())?;
        dom.serialize().map_err(|e| e.to_string())
    })
    .map_err(|e| EngineError::Decode(format!("SVG parse: {e}")))?
    .map_err(EngineError::Encode)?;
    Ok(output.into_bytes())
}
