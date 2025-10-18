#[derive(Debug)]
pub enum IVFError {
    UnexpectedEof,
    InvalidSignature,
    UnsupportedVersion(u16),
    InvalidHeaderSize(u16),
    FrameTooShort,
}

#[derive(Debug, Clone)]
pub struct IVFHeader {
    pub fourcc: [u8; 4],
    pub width: u16,
    pub height: u16,
    pub framerate_num: u32,
    pub framerate_den: u32,
    pub num_frames: u64,
}

#[derive(Debug, Clone)]
pub struct IVFFrame<'a> {
    pub pts: u64,
    pub data: &'a [u8],
}

pub struct IVFParser<'a> {
    data: &'a [u8],
    cursor: usize,
    pub header: IVFHeader,
}

impl<'a> IVFParser<'a> {
    pub fn new(data: &'a [u8]) -> Result<Self, IVFError> {
        if data.len() < 32 {
            return Err(IVFError::UnexpectedEof);
        }

        if &data[0..4] != b"DKIF" {
            return Err(IVFError::InvalidSignature);
        }

        let version = u16::from_le_bytes(data[4..6].try_into().unwrap());
        if version != 0 {
            return Err(IVFError::UnsupportedVersion(version));
        }

        let header_size = u16::from_le_bytes(data[6..8].try_into().unwrap());
        if header_size != 32 {
            return Err(IVFError::InvalidHeaderSize(header_size));
        }

        let header = IVFHeader {
            fourcc: data[8..12].try_into().unwrap(),
            width: u16::from_le_bytes(data[12..14].try_into().unwrap()),
            height: u16::from_le_bytes(data[14..16].try_into().unwrap()),
            framerate_num: u32::from_le_bytes(data[16..20].try_into().unwrap()),
            framerate_den: u32::from_le_bytes(data[20..24].try_into().unwrap()),
            num_frames: u64::from_le_bytes(data[24..32].try_into().unwrap()),
        };

        Ok(Self {
            data,
            cursor: 32,
            header,
        })
    }

    pub fn next_frame(&mut self) -> Result<Option<IVFFrame<'a>>, IVFError> {
        if self.cursor + 12 > self.data.len() {
            return Ok(None);
        }

        let frame_size =
            u32::from_le_bytes(self.data[self.cursor..self.cursor + 4].try_into().unwrap())
                as usize;
        let pts = u64::from_le_bytes(
            self.data[self.cursor + 4..self.cursor + 12]
                .try_into()
                .unwrap(),
        );

        self.cursor += 12;
        if self.cursor + frame_size > self.data.len() {
            return Err(IVFError::FrameTooShort);
        }

        let frame_data = &self.data[self.cursor..self.cursor + frame_size];
        self.cursor += frame_size;

        Ok(Some(IVFFrame {
            pts,
            data: frame_data,
        }))
    }
}

impl std::error::Error for IVFError {}
impl std::fmt::Display for IVFError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        use IVFError::*;
        match self {
            UnexpectedEof => write!(f, "Unexpected EOF"),
            InvalidSignature => write!(f, "Invalid IVF signature"),
            UnsupportedVersion(v) => write!(f, "Unsupported IVF version {}", v),
            InvalidHeaderSize(s) => write!(f, "Invalid IVF header size {}", s),
            FrameTooShort => write!(f, "Frame data too short"),
        }
    }
}
