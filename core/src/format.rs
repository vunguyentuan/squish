//! Container sniffing by magic bytes. Extensions lie; headers don't.

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Unknown = 0,
    Png = 1,
    Jpeg = 2,
    WebP = 3,
    Avif = 4,
    Svg = 5,
    Gif = 6,
    Tiff = 7,
    Bmp = 8,
    Heic = 9,
}

impl Format {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::Png,
            2 => Self::Jpeg,
            3 => Self::WebP,
            4 => Self::Avif,
            5 => Self::Svg,
            6 => Self::Gif,
            7 => Self::Tiff,
            8 => Self::Bmp,
            9 => Self::Heic,
            _ => Self::Unknown,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Png => "PNG",
            Self::Jpeg => "JPEG",
            Self::WebP => "WebP",
            Self::Avif => "AVIF",
            Self::Svg => "SVG",
            Self::Gif => "GIF",
            Self::Tiff => "TIFF",
            Self::Bmp => "BMP",
            Self::Heic => "HEIC",
        }
    }
}

pub fn detect(data: &[u8]) -> Format {
    if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Format::Png;
    }
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Format::Jpeg;
    }
    if data.len() >= 12 && &data[0..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        return Format::WebP;
    }
    if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        return Format::Gif;
    }
    if data.starts_with(b"II*\0") || data.starts_with(b"MM\0*") {
        return Format::Tiff;
    }
    if data.starts_with(b"BM") && data.len() > 26 {
        return Format::Bmp;
    }
    if data.len() >= 12 && &data[4..8] == b"ftyp" {
        let brand = &data[8..12];
        return match brand {
            b"avif" | b"avis" => Format::Avif,
            b"heic" | b"heix" | b"hevc" | b"heim" | b"heis" | b"mif1" | b"msf1" => Format::Heic,
            _ => Format::Unknown,
        };
    }
    if looks_like_svg(data) {
        return Format::Svg;
    }
    Format::Unknown
}

fn looks_like_svg(data: &[u8]) -> bool {
    let head = &data[..data.len().min(4096)];
    let Ok(text) = std::str::from_utf8(head).or_else(|e| std::str::from_utf8(&head[..e.valid_up_to()])) else {
        return false;
    };
    let text = text.trim_start_matches('\u{feff}').trim_start();
    text.starts_with('<') && text.contains("<svg")
}

/// PNG with an `acTL` chunk before the first `IDAT` is an APNG.
pub fn is_animated_png(data: &[u8]) -> bool {
    png_chunks(data).any(|(name, _)| name == b"acTL")
}

/// Animated WebP files carry an `ANIM` chunk inside the RIFF container.
pub fn is_animated_webp(data: &[u8]) -> bool {
    riff_chunks(data).any(|(name, _)| name == b"ANIM")
}

/// True when the WebP bitstream is VP8L (lossless).
pub fn is_lossless_webp(data: &[u8]) -> bool {
    riff_chunks(data).any(|(name, _)| name == b"VP8L")
}

/// Walks PNG chunks up to (and including) the first IDAT.
fn png_chunks(data: &[u8]) -> impl Iterator<Item = (&[u8], &[u8])> {
    let mut pos = 8;
    std::iter::from_fn(move || {
        if pos + 8 > data.len() {
            return None;
        }
        let len = u32::from_be_bytes(data[pos..pos + 4].try_into().ok()?) as usize;
        let name = &data[pos + 4..pos + 8];
        let body_start = pos + 8;
        let body_end = body_start.checked_add(len)?.min(data.len());
        pos = body_end + 4; // skip CRC
        if name == b"IDAT" {
            pos = data.len();
        }
        Some((name, &data[body_start..body_end]))
    })
}

fn riff_chunks(data: &[u8]) -> impl Iterator<Item = (&[u8], &[u8])> {
    let mut pos = 12;
    std::iter::from_fn(move || {
        if pos + 8 > data.len() {
            return None;
        }
        let name = &data[pos..pos + 4];
        let len = u32::from_le_bytes(data[pos + 4..pos + 8].try_into().ok()?) as usize;
        let body_start = pos + 8;
        let body_end = body_start.checked_add(len)?.min(data.len());
        pos = body_end + (len & 1);
        Some((name, &data[body_start..body_end]))
    })
}
