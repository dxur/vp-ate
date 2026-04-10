//! Bit-level reading and VP8 boolean arithmetic decoding.
//!
//! This module provides two main components:
//! - [`BitReader`]: For reading individual bits and bytes from a byte slice
//! - [`BoolDecoder`]: For decoding VP8's arithmetic-coded (boolean) bitstream
//!
//! VP8 uses arithmetic coding for most of its entropy-coded data, which allows
//! for more efficient compression than simple bit-level encoding.

use serde::Serialize;
use std::fmt;

#[derive(Serialize, Clone, Copy, Debug)]
pub struct BitDecision {
    pub prob: u8,
    pub bit: u8,
}

#[derive(Serialize, Clone, Copy, Debug)]
pub struct BlockDebug {
    pub plane: u8,
    pub has_coeff: bool,
    pub raw_coeffs: [i32; 16],
    pub bd1_idx_after: usize,
    pub bd1_range_after: u32,
    pub bd1_value_after: u32,
    pub bd1_byte_offset_after: usize,
}

#[derive(Serialize, Clone, Copy, Debug)]
pub struct BoolDecoderState {
    pub range: u32,
    pub value: u32,
    pub byte_offset: usize,
}

/// Errors that can occur during bit reading or boolean decoding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BitError {
    /// Attempted to read past the end of the input data.
    UnexpectedEOF,
}

type Result<T> = std::result::Result<T, BitError>;

impl fmt::Display for BitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BitError::UnexpectedEOF => write!(f, "Unexpected end of input"),
        }
    }
}

/// A bit-level reader for reading individual bits from a byte slice.
///
/// `BitReader` maintains a position in both bytes and bits, allowing you to read
/// data at bit granularity. Bits are read in MSB-first order within each byte.
///
/// # Examples
///
/// ```
/// # use vp_ate::bit::BitReader;
/// let data = &[0b10110011, 0b11001010];
/// let mut reader = BitReader::new(data);
/// assert_eq!(reader.read_bit().unwrap(), 1); // MSB of first byte
/// assert_eq!(reader.read_bit().unwrap(), 0);
/// ```
pub struct BitReader<'a> {
    /// The underlying byte slice being read from.
    pub data: &'a [u8],
    /// Current byte position in the data.
    pub byte_pos: usize,
    /// Current bit position within the current byte (0-7).
    pub bit_pos: u8,
}

impl<'a> BitReader<'a> {
    /// Creates a new `BitReader` from the given byte slice.
    ///
    /// The reader starts at the beginning of the data (byte 0, bit 0).
    pub fn new(data: &'a [u8]) -> Self {
        Self {
            data,
            byte_pos: 0,
            bit_pos: 0,
        }
    }

    /// Reads a single bit from the stream.
    ///
    /// Bits are read in MSB-first order within each byte. After reading 8 bits,
    /// the reader automatically advances to the next byte.
    ///
    /// # Returns
    ///
    /// Returns `Ok(0)` or `Ok(1)` on success, or `Err(BitError::UnexpectedEOF)`
    /// if there are no more bits to read.
    pub fn read_bit(&mut self) -> Result<u8> {
        if self.byte_pos >= self.data.len() {
            return Err(BitError::UnexpectedEOF);
        }

        let byte = self.data[self.byte_pos];
        let bit = (byte >> (7 - self.bit_pos)) & 1;

        self.bit_pos += 1;
        if self.bit_pos == 8 {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }

        Ok(bit)
    }

    /// Reads multiple bits and returns them as a `u32`.
    ///
    /// Reads `n` bits (up to 32) and assembles them into a single `u32` value,
    /// with the first bit read becoming the MSB.
    ///
    /// # Panics
    ///
    /// Panics if `n > 32`.
    pub fn read_bits(&mut self, n: u8) -> Result<u32> {
        if n > 32 {
            panic!("Cannot read more than 32 bits at a time");
        }

        let mut value = 0u32;
        for _ in 0..n {
            value = (value << 1) | self.read_bit()? as u32;
        }
        Ok(value)
    }

    /// Reads a single bit and returns it as a boolean.
    ///
    /// This is a convenience method that returns `true` for 1 and `false` for 0.
    pub fn read_flag(&mut self) -> Result<bool> {
        Ok(self.read_bit()? != 0)
    }

    /// Aligns the reader to the next byte boundary.
    ///
    /// If the reader is not currently at a byte boundary (bit_pos != 0),
    /// this advances to the start of the next byte, discarding any remaining
    /// bits in the current byte.
    pub fn align_byte(&mut self) -> Result<()> {
        if self.bit_pos != 0 {
            self.bit_pos = 0;
            if self.data.len() <= self.byte_pos + 1 {
                return Err(BitError::UnexpectedEOF);
            }
            self.byte_pos += 1;
        }
        Ok(())
    }

    /// Reads a full byte from a byte-aligned position.
    ///
    /// This method first aligns to a byte boundary, then reads 8 bits.
    pub fn read_byte(&mut self) -> Result<u8> {
        self.align_byte()?;
        Ok(self.read_bits(8)? as u8)
    }

    /// Reads `N` bytes from a byte-aligned position.
    ///
    /// This method first aligns to a byte boundary, then reads `N` complete bytes.
    pub fn read_bytes<const N: usize>(&mut self) -> Result<[u8; N]> {
        self.align_byte()?;
        let mut buf = [0u8; N];
        for i in buf.iter_mut() {
            *i = self.read_byte()?;
        }
        Ok(buf)
    }

    /// Checks if the end of the input has been reached.
    ///
    /// Returns `true` if all bytes have been consumed.
    pub fn is_eof(&self) -> bool {
        self.byte_pos >= self.data.len()
    }
}

impl<'a> Clone for BitReader<'a> {
    fn clone(&self) -> Self {
        Self {
            data: self.data,
            byte_pos: self.byte_pos,
            bit_pos: self.bit_pos,
        }
    }
}

impl<'a> std::fmt::Debug for BitReader<'a> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BitReader")
            // .field("data", &self.data)
            .field("data.len", &self.data.len())
            .field("byte_pos", &self.byte_pos)
            .field("bit_pos", &self.bit_pos)
            .finish()
    }
}

/// A boolean arithmetic decoder for VP8's entropy-coded bitstream.
///
/// VP8 uses arithmetic coding (also called "boolean coding" in the spec) to compress
/// most of its syntax elements. This is more efficient than simple bit-level encoding
/// because it can encode symbols with non-power-of-2 probabilities.
///
/// The decoder maintains a range and a value, and decodes each boolean by comparing
/// the value against a split point determined by the probability. This implementation
/// follows the VP8 bitstream specification.
///
/// # Algorithm
///
/// For each boolean to decode:
/// 1. Split the current range based on the probability (0-255)
/// 2. Compare the value against the split point
/// 3. Update range and value based on which half was chosen
/// 4. Renormalize when range gets too small
#[derive(Debug)]
pub struct BoolDecoder<'a, 'b> {
    br: &'a mut BitReader<'b>,
    range: u32,
    value: u32,
    bit_count: i32,
    pub log: Vec<BitDecision>,
}

impl<'a, 'b> BoolDecoder<'a, 'b> {
    /// Initializes a new boolean decoder from a compressed data partition.
    ///
    /// The first two bytes of the partition are read to initialize the `value`.
    /// The `range` starts at 255.
    pub fn new(br: &'a mut BitReader<'b>) -> Result<Self> {
        let mut value: u32 = 0;

        for _ in 0..2 {
            value = (value << 8) | br.read_byte()? as u32;
        }

        Ok(Self {
            br,
            range: 255,
            value,
            bit_count: 0,
            log: Vec::new(),
        })
    }

    pub fn get_state(&self) -> BoolDecoderState {
        BoolDecoderState {
            range: self.range,
            value: self.value,
            byte_offset: self.br.byte_pos,
        }
    }

    pub fn count(&self) -> usize {
        self.log.len()
    }

    /// Reads a boolean with 50/50 probability (probability = 128).
    ///
    /// This is a convenience method for reading a boolean that's equally likely
    /// to be 0 or 1.
    pub fn read_flag(&mut self) -> Result<u8> {
        self.read_bool(128)
    }

    /// Reads a boolean with a given probability.
    ///
    /// The `prob` parameter (0-255) represents the probability that the decoded
    /// value is 0. A probability of 128 means 50/50, higher values mean 0 is more
    /// likely, lower values mean 1 is more likely.
    ///
    /// This is the core arithmetic decoding operation. The range is split based on
    /// the probability, and the value is compared against the split point to determine
    /// which symbol was encoded.
    pub fn read_bool(&mut self, prob: u8) -> Result<u8> {
        let split = 1 + (((self.range - 1) * prob as u32) >> 8);
        let split_shifted = split << 8;
        let retval: u8;

        if self.value >= split_shifted {
            // encoded a one
            retval = 1;
            self.range -= split;
            self.value -= split_shifted;
        } else {
            // encoded a zero
            retval = 0;
            self.range = split;
        }

        self.log.push(BitDecision { prob, bit: retval });

        while self.range < 128 {
            self.value <<= 1;
            self.range <<= 1;

            self.bit_count += 1;
            if self.bit_count == 8 {
                self.bit_count = 0;
                self.value |= self.br.read_byte()? as u32;
            }
        }

        Ok(retval)
    }

    /// Reads a literal value of `num_bits` bits.
    ///
    /// Each bit is decoded with 50/50 probability. This is used for reading
    /// fixed-length fields within the arithmetic-coded stream.
    pub fn read_literal(&mut self, num_bits: usize) -> Result<u32> {
        let mut v = 0;
        for _ in 0..num_bits {
            v = (v << 1) | self.read_bool(128)? as u32;
        }
        Ok(v)
    }

    /// Reads a signed literal value.
    ///
    /// The first bit indicates the sign (0 = positive, 1 = negative),
    /// followed by `num_bits - 1` magnitude bits.
    pub fn read_signed_literal(&mut self, num_bits: usize) -> Result<i32> {
        if num_bits == 0 {
            return Ok(0);
        }

        let sign = self.read_bool(128)?;
        let mut v: i32 = 0;

        for _ in 1..num_bits {
            v = (v << 1) | self.read_bool(128)? as i32;
        }

        Ok(if sign != 0 { -v } else { v })
    }

    /// Reads a value encoded using a binary tree.
    ///
    /// VP8 uses binary trees to encode symbols with varying probabilities.
    /// The tree `t` defines the structure, and `p` provides the probability
    /// for each decision node. Positive values in the tree are node indices,
    /// negative values are leaf symbols (negated).
    pub fn read_treed(&mut self, t: &[i8], p: &[u8]) -> Result<i8> {
        let mut i = 0i8;
        loop {
            let prob = p[(i >> 1) as usize];
            let index = i.wrapping_add(self.read_bool(prob)? as i8) as usize;
            i = t[index];
            if i <= 0 {
                break;
            }
        }
        Ok(-i)
    }
}

#[cfg(test)]
mod tests {
    use std::io::Read;

    use super::*;

    #[test]
    fn bool_decode_stdin() {
        let mut stdin = std::io::stdin();

        let mut n_buf = [0u8; 1];
        stdin.read_exact(&mut n_buf).unwrap();
        let n_props = n_buf[0] as usize;

        let mut props = vec![0u8; n_props];
        stdin.read_exact(&mut props).unwrap();

        let mut data = Vec::new();
        stdin.read_to_end(&mut data).unwrap();

        let mut br = BitReader::new(&data);
        let mut decoder = BoolDecoder::new(&mut br).unwrap();

        for prop in props {
            let b = decoder.read_bool(prop).unwrap();
            print!("{}", b);
        }
    }
}
