//! Just enough EXIF to keep photos upright after metadata is stripped.

/// Reads the orientation tag (0x0112) from an APP1 payload that starts with `Exif\0\0`.
pub fn orientation(app1: &[u8]) -> Option<u16> {
    let tiff = app1.strip_prefix(b"Exif\0\0")?;
    let big_endian = match tiff.get(0..2)? {
        b"MM" => true,
        b"II" => false,
        _ => return None,
    };
    let u16_at = |off: usize| -> Option<u16> {
        let b: [u8; 2] = tiff.get(off..off + 2)?.try_into().ok()?;
        Some(if big_endian { u16::from_be_bytes(b) } else { u16::from_le_bytes(b) })
    };
    let u32_at = |off: usize| -> Option<u32> {
        let b: [u8; 4] = tiff.get(off..off + 4)?.try_into().ok()?;
        Some(if big_endian { u32::from_be_bytes(b) } else { u32::from_le_bytes(b) })
    };
    let ifd = u32_at(4)? as usize;
    let count = u16_at(ifd)? as usize;
    (0..count).find_map(|i| {
        let entry = ifd + 2 + i * 12;
        (u16_at(entry)? == 0x0112).then(|| u16_at(entry + 8)).flatten()
    })
}

/// A 34-byte EXIF block carrying only the orientation tag.
pub fn minimal_orientation_app1(orientation: u16) -> Vec<u8> {
    let mut out = Vec::with_capacity(34);
    out.extend_from_slice(b"Exif\0\0");
    out.extend_from_slice(b"MM\0\x2a");
    out.extend_from_slice(&8u32.to_be_bytes()); // IFD0 offset
    out.extend_from_slice(&1u16.to_be_bytes()); // one entry
    out.extend_from_slice(&0x0112u16.to_be_bytes());
    out.extend_from_slice(&3u16.to_be_bytes()); // SHORT
    out.extend_from_slice(&1u32.to_be_bytes());
    out.extend_from_slice(&orientation.to_be_bytes());
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(&0u32.to_be_bytes()); // no next IFD
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_orientation() {
        for o in 1..=8 {
            assert_eq!(orientation(&minimal_orientation_app1(o)), Some(o));
        }
    }
}
