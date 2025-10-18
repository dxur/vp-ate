use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BitError {
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

pub struct BitReader<'a> {
    pub data: &'a [u8],
    pub byte_pos: usize,
    pub bit_pos: u8,
}

impl<'a> BitReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self {
            data,
            byte_pos: 0,
            bit_pos: 0,
        }
    }

    /// Read a single bit (as 0 or 1)
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

    /// Read multiple bits (up to 32), returned as u32
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

    /// Read a single bit and return as a boolean flag
    pub fn read_flag(&mut self) -> Result<bool> {
        Ok(self.read_bit()? != 0)
    }

    /// Align to next byte boundary
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

    /// Read next byte aligned byte
    pub fn read_byte(&mut self) -> Result<u8> {
        self.align_byte()?;
        Ok(self.read_bits(8)? as u8)
    }

    /// Return the next N untouched bytes and advance
    pub fn read_bytes<const N: usize>(&mut self) -> Result<[u8; N]> {
        self.align_byte()?;
        let mut buf = [0u8; N];
        for i in buf.iter_mut() {
            *i = self.read_byte()?;
        }
        Ok(buf)
    }

    /// Check if end of input has been reached
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
            .field("data", &self.data)
            .field("data.len", &self.data.len())
            .field("byte_pos", &self.byte_pos)
            .field("bit_pos", &self.bit_pos)
            .finish()
    }
}

#[derive(Debug)]
pub struct BoolDecoder<'a, 'b> {
    br: &'a mut BitReader<'b>,
    range: u32,
    value: u32,
    bit_count: i32,
}

impl<'a, 'b> BoolDecoder<'a, 'b> {
    /// Initialize a new boolean decoder from the given compressed partition
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
        })
    }

    /// Read a single bool (bit) encoded with a probability of 128 (1/2)
    pub fn read_flag(&mut self) -> Result<u8> {
        self.read_bool(128)
    }

    /// Read a single bool (bit) encoded with a given probability (0–255)
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

    /// Read a literal value of `num_bits` bits, each bit with probability 128 (1/2)
    pub fn read_literal(&mut self, num_bits: usize) -> Result<u32> {
        let mut v = 0;
        for _ in 0..num_bits {
            v = (v << 1) | self.read_bool(128)? as u32;
        }
        Ok(v)
    }

    /// Read a signed literal value of `num_bits` bits
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

    /// Read a tree coded value
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
