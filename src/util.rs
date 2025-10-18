use std::io::{self, Write};

pub fn write_to_wepb(file: &str, data: &[u8]) -> io::Result<()> {
    let data_size = data.len() as u32;
    let riff_size = 4 + 4 + 4 + 4 + 4 + data_size;
    let riff_size_field = riff_size - 8;

    let mut webp_data = Vec::new();
    webp_data.extend_from_slice(b"RIFF");
    webp_data.extend_from_slice(&riff_size_field.to_le_bytes());
    webp_data.extend_from_slice(b"WEBP");
    webp_data.extend_from_slice(b"VP8 ");
    webp_data.extend_from_slice(&data_size.to_le_bytes());
    webp_data.extend_from_slice(&data);

    let mut out = std::fs::File::create(file)?;
    out.write_all(&webp_data)
}
