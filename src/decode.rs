use crate::frame::VP8Frame;

impl VP8Frame {
    pub fn decode(self, _buffer: &mut Vec<u32>) -> Result<(usize, usize), &'static str> {
        Ok((0, 0))
    }
}
