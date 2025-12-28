//! Utility functions for VP8 decoding.
//!
//! This module provides:
//! - Inverse transforms (IDCT and IWHT) for reconstructing pixel data
//! - Color space conversion (YUV to RGB)
//! - Debug utilities for visualization

use std::io::{self, Write};

/// Dumps a 2D image array to a PGM file for debugging.
///
/// Creates a grayscale PGM (Portable GrayMap) file at `./debug.pgm`.
pub fn dump<const W: usize, const H: usize>(img: &[[u8; W]; H]) {
    let mut f = std::fs::File::create("./debug.pgm").unwrap();
    writeln!(f, "P2\n{W} {H}\n255").unwrap();
    for r in img {
        for p in r {
            write!(f, "{p:>3} ").unwrap();
        }
        writeln!(f).unwrap();
    }
}

/// Writes VP8 frame data to a WebP file.
///
/// Wraps the raw VP8 bitstream in a WebP RIFF container.
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

/// Draws a macroblock grid overlay on the frame buffer for debugging.
///
/// # Parameters
///
/// - `w`, `h`: Frame dimensions in pixels
/// - `gw`, `gh`: Grid cell dimensions (typically 16x16 for macroblocks)
/// - `c`: Color value to use for grid lines (in packed 32-bit format)
/// - `buffer`: Frame buffer to draw into
pub fn draw_mb_grid(w: usize, h: usize, gw: usize, gh: usize, c: u32, buffer: &mut Vec<u32>) {
    let mb_cols = w / gw;
    let mb_rows = h / gh;

    for col in 0..=mb_cols {
        let x = col * gw;
        if x >= w {
            break;
        }
        for y in 0..h {
            let idx = y * w + x;
            if idx < buffer.len() {
                buffer[idx] = c;
            }
        }
    }

    for row in 0..=mb_rows {
        let y = row * gw;
        if y >= h {
            break;
        }
        for x in 0..w {
            let idx = y * w + x;
            if idx < buffer.len() {
                buffer[idx] = c;
            }
        }
    }
}

/// Converts a YUV pixel to RGB in-place.
///
/// The pixel is stored in a packed 32-bit format: `0x00YYUUVV` (input)
/// becomes `0xAARRGGBB` (output).
///
/// Uses the ITU-R BT.601 conversion matrix.
pub fn yuv2rgb(pix: &mut u32) {
    let y = ((*pix >> 16) & 0xFF) as i32;
    let u = ((*pix >> 8) & 0xFF) as i32;
    let v = (*pix & 0xFF) as i32;

    let u = u - 128;
    let v = v - 128;

    let r = y + (1786 * v) / 1024;
    let g = y - (879 * u + 1836 * v) / 1024;
    let b = y + (2275 * u) / 1024;

    let r = r.max(0).min(255) as u8;
    let g = g.max(0).min(255) as u8;
    let b = b.max(0).min(255) as u8;

    *pix = (0xFF << 24) | ((r as u32) << 16) | ((g as u32) << 8) | (b as u32);
}

/// Packs three 8-bit color components into a 32-bit value.
///
/// Format: `0x00AABBCC` where A, B, C are the three components.
pub fn pack_color(a: u8, b: u8, c: u8) -> u32 {
    ((a as u32) << 16) | ((b as u32) << 8) | (c as u32)
}

/// Unpacks a 32-bit color value into three 8-bit components.
pub fn unpack_color(p: u32) -> (u8, u8, u8) {
    let a = ((p >> 16) & 0xFF) as u8;
    let b = ((p >> 8) & 0xFF) as u8;
    let c = (p & 0xFF) as u8;
    (a, b, c)
}

/// Extracts the first (most significant) color component.
pub fn a_of(p: u32) -> u8 {
    ((p >> 16) & 0xFF) as u8
}

/// Extracts the second color component.
pub fn b_of(p: u32) -> u8 {
    ((p >> 8) & 0xFF) as u8
}

/// Extracts the third (least significant) color component.
pub fn c_of(p: u32) -> u8 {
    (p & 0xFF) as u8
}

/// 16-bit fixed-point constant: cos(π/8) × √2 - 1
const CONST1: i64 = 20091;

/// 16-bit fixed-point constant: sin(π/8) × √2
const CONST2: i64 = 35468;

/// Performs inverse discrete cosine transform on a 4x4 block.
///
/// This is the reference implementation using 64-bit arithmetic to avoid overflow.
/// The input block should contain 16 DCT coefficients in row-major order.
///
/// # Algorithm
///
/// Implements the 2D IDCT as two 1D transforms:
/// 1. Transform each column (vertical)
/// 2. Transform each row (horizontal)
///
/// The transform uses fixed-point arithmetic with 16-bit precision.
pub fn idct4x4(block: &mut [i32]) {
    // The intermediate results may overflow the types, so we stretch the type.
    fn fetch(block: &[i32], idx: usize) -> i64 {
        i64::from(block[idx])
    }

    // Perform one length check up front to avoid subsequent bounds checks in this function
    assert!(block.len() >= 16);

    for i in 0usize..4 {
        let a1 = fetch(block, i) + fetch(block, 8 + i);
        let b1 = fetch(block, i) - fetch(block, 8 + i);

        let t1 = (fetch(block, 4 + i) * CONST2) >> 16;
        let t2 = fetch(block, 12 + i) + ((fetch(block, 12 + i) * CONST1) >> 16);
        let c1 = t1 - t2;

        let t1 = fetch(block, 4 + i) + ((fetch(block, 4 + i) * CONST1) >> 16);
        let t2 = (fetch(block, 12 + i) * CONST2) >> 16;
        let d1 = t1 + t2;

        block[i] = (a1 + d1) as i32;
        block[4 + i] = (b1 + c1) as i32;
        block[4 * 3 + i] = (a1 - d1) as i32;
        block[4 * 2 + i] = (b1 - c1) as i32;
    }

    for i in 0usize..4 {
        let a1 = fetch(block, 4 * i) + fetch(block, 4 * i + 2);
        let b1 = fetch(block, 4 * i) - fetch(block, 4 * i + 2);

        let t1 = (fetch(block, 4 * i + 1) * CONST2) >> 16;
        let t2 = fetch(block, 4 * i + 3) + ((fetch(block, 4 * i + 3) * CONST1) >> 16);
        let c1 = t1 - t2;

        let t1 = fetch(block, 4 * i + 1) + ((fetch(block, 4 * i + 1) * CONST1) >> 16);
        let t2 = (fetch(block, 4 * i + 3) * CONST2) >> 16;
        let d1 = t1 + t2;

        block[4 * i] = ((a1 + d1 + 4) >> 3) as i32;
        block[4 * i + 3] = ((a1 - d1 + 4) >> 3) as i32;
        block[4 * i + 1] = ((b1 + c1 + 4) >> 3) as i32;
        block[4 * i + 2] = ((b1 - c1 + 4) >> 3) as i32;
    }
}

/// Performs inverse Walsh-Hadamard transform on a 4x4 block.
///
/// Used for the second-order DC coefficients in VP8 (Y2 blocks).
/// The WHT is simpler than the DCT and doesn't require multiplication.
///
/// # Algorithm
///
/// Applies the WHT in two passes:
/// 1. Transform each column
/// 2. Transform each row
pub fn iwht4x4(block: &mut [i32]) {
    // Perform one length check up front to avoid subsequent bounds checks in this function
    assert!(block.len() >= 16);

    for i in 0usize..4 {
        let a1 = block[i] + block[12 + i];
        let b1 = block[4 + i] + block[8 + i];
        let c1 = block[4 + i] - block[8 + i];
        let d1 = block[i] - block[12 + i];

        block[i] = a1 + b1;
        block[4 + i] = c1 + d1;
        block[8 + i] = a1 - b1;
        block[12 + i] = d1 - c1;
    }

    for block in block.chunks_exact_mut(4) {
        let a1 = block[0] + block[3];
        let b1 = block[1] + block[2];
        let c1 = block[1] - block[2];
        let d1 = block[0] - block[3];

        let a2 = a1 + b1;
        let b2 = c1 + d1;
        let c2 = a1 - b1;
        let d2 = d1 - c1;

        block[0] = (a2 + 3) >> 3;
        block[1] = (b2 + 3) >> 3;
        block[2] = (c2 + 3) >> 3;
        block[3] = (d2 + 3) >> 3;
    }
}

/// VP8-specific inverse Walsh-Hadamard transform for 4x4 blocks.
///
/// This is the production version used in the decoder. Operates on a fixed-size
/// array for better performance.
pub fn vp8_iwht4x4(input: &mut [i32; 16]) {
    let mut tmp = [0i32; 16];

    // Vertical
    for i in 0..4 {
        let a1 = input[0 + i] + input[12 + i];
        let b1 = input[4 + i] + input[8 + i];
        let c1 = input[4 + i] - input[8 + i];
        let d1 = input[0 + i] - input[12 + i];

        tmp[0 + i] = a1 + b1;
        tmp[4 + i] = d1 + c1;
        tmp[8 + i] = a1 - b1;
        tmp[12 + i] = d1 - c1;
    }

    // Horizontal
    for i in (0..16).step_by(4) {
        let a1 = tmp[i + 0] + tmp[i + 3];
        let b1 = tmp[i + 1] + tmp[i + 2];
        let c1 = tmp[i + 1] - tmp[i + 2];
        let d1 = tmp[i + 0] - tmp[i + 3];

        input[i + 0] = (a1 + b1 + 3) >> 3;
        input[i + 1] = (d1 + c1 + 3) >> 3;
        input[i + 2] = (a1 - b1 + 3) >> 3;
        input[i + 3] = (d1 - c1 + 3) >> 3;
    }
}

/// VP8-specific inverse DCT for 4x4 blocks.
///
/// This is the production version used in the decoder. Uses 32-bit arithmetic
/// and operates on a fixed-size array.
///
/// # Algorithm
///
/// Implements the 2D IDCT as specified in the VP8 bitstream specification,
/// using fixed-point arithmetic with rounding.
pub fn vp8_idct4x4(block: &mut [i32; 16]) {
    const CONST1: i32 = 20091;
    const CONST2: i32 = 35468;

    for i in 0usize..4 {
        let a1 = block[i] + block[8 + i];
        let b1 = block[i] - block[8 + i];

        let t1 = (block[4 + i] * CONST2) >> 16;
        let t2 = block[12 + i] + ((block[12 + i] * CONST1) >> 16);
        let c1 = t1 - t2;

        let t1 = block[4 + i] + ((block[4 + i] * CONST1) >> 16);
        let t2 = (block[12 + i] * CONST2) >> 16;
        let d1 = t1 + t2;

        block[i] = (a1 + d1) as i32;
        block[4 + i] = (b1 + c1) as i32;
        block[4 * 3 + i] = (a1 - d1) as i32;
        block[4 * 2 + i] = (b1 - c1) as i32;
    }

    for i in 0usize..4 {
        let a1 = block[4 * i] + block[4 * i + 2];
        let b1 = block[4 * i] - block[4 * i + 2];

        let t1 = (block[4 * i + 1] * CONST2) >> 16;
        let t2 = block[4 * i + 3] + ((block[4 * i + 3] * CONST1) >> 16);
        let c1 = t1 - t2;

        let t1 = block[4 * i + 1] + ((block[4 * i + 1] * CONST1) >> 16);
        let t2 = (block[4 * i + 3] * CONST2) >> 16;
        let d1 = t1 + t2;

        block[4 * i] = ((a1 + d1 + 4) >> 3) as i32;
        block[4 * i + 3] = ((a1 - d1 + 4) >> 3) as i32;
        block[4 * i + 1] = ((b1 + c1 + 4) >> 3) as i32;
        block[4 * i + 2] = ((b1 - c1 + 4) >> 3) as i32;
    }
}
