use strum::FromRepr;

use crate::{
    bit::{BitError, BitReader, BoolDecoder},
    frame::VP8FrameHeader,
    tables::KF_BMODE_PROB,
};

#[derive(Debug, PartialEq, Eq, FromRepr)]
#[repr(i8)]
pub enum IntraMBMode {
    DcPred, /* predict DC using row above and column to the left */
    VPred,  /* predict rows using row above */
    HPred,  /* predict columns using column to the left */
    TmPred, /* propagate second differences a la "True Motion" */
    BPred,  /* each Y subblock is independently predicted */
}

impl IntraMBMode {
    pub const NUM_UV_MODES: usize = 4; // first four modes apply to chroma
    pub const NUM_YMODES: usize = 5; // all modes apply to luma
}

const DEFAULT_YMODE_PROB: [u8; IntraMBMode::NUM_YMODES - 1] = [112, 86, 140, 37];
const DEFAULT_UV_MODE_PROB: [u8; IntraMBMode::NUM_UV_MODES - 1] = [162, 101, 204];
const KF_YMODE_PROB: [u8; IntraMBMode::NUM_YMODES - 1] = [145, 156, 163, 128];

#[rustfmt::skip]
const YMODE_TREE: [i8; 2 * (IntraMBMode::NUM_YMODES - 1)] = {
    use IntraMBMode::*;
    [
        -(DcPred as i8), 2, 4, 6,
        -(VPred as i8),
        -(HPred as i8),
        -(TmPred as i8),
        -(BPred as i8),
    ]
};

#[rustfmt::skip]
const KF_YMODE_TREE: [i8; 2 * (IntraMBMode::NUM_YMODES - 1)] = {
    use IntraMBMode::*;
    [
        -(BPred as i8), 2, 4, 6,
        -(DcPred as i8),
        -(VPred as i8),
        -(HPred as i8),
        -(TmPred as i8),
    ]
};

#[derive(Debug, Clone, Copy, PartialEq, PartialOrd, FromRepr)]
#[repr(i8)]
pub enum IntraBMode {
    BDcPred, /* predict DC using row above and column to the left */
    BTmPred, /* propagate second differences a la "True Motion" */
    BVePred, /* predict rows using row above */
    BHePred, /* predict columns using column to the left */
    BLdPred, /* southwest (left and down) 45 degree diagonal prediction */
    BRdPred, /* southeast (right and down) "" */
    BVrPred, /* SSE (vertical right) diagonal prediction */
    BVlPred, /* SSW (vertical left) "" */
    BHdPred, /* ESE (horizontal down) "" */
    BHuPred, /* ENE (horizontal up) "" */
}

impl IntraBMode {
    pub const NUM_BMODES: usize = 10;
}

#[rustfmt::skip]
const BMODE_TREE: [i8; 2 * (IntraBMode::NUM_BMODES - 1)] = {
    use IntraBMode::*;
    [
        -(BDcPred as i8), 2,
        -(BTmPred as i8), 4,
        -(BVePred as i8), 6, 8, 12,
        -(BHePred as i8), 10,
        -(BRdPred as i8),
        -(BVrPred as i8),
        -(BLdPred as i8), 14,
        -(BVlPred as i8), 16,
        -(BHdPred as i8),
        -(BHuPred as i8),
    ]
};

const KF_UV_MODE_PROB: [u8; IntraMBMode::NUM_UV_MODES - 1] = [142, 114, 183];

#[rustfmt::skip]
const UV_MODE_TREE: [i8; 2 * (IntraMBMode::NUM_UV_MODES - 1)] = {
    use IntraMBMode::*;
    [
        -(DcPred as i8), 2,
        -(VPred as i8), 4,
        -(HPred as i8),
        -(TmPred as i8),
    ]
};

#[derive(Debug)]
pub enum MacroblockError {
    FrameTooShort,
}

type Result<T> = std::result::Result<T, MacroblockError>;

impl From<BitError> for MacroblockError {
    fn from(_: BitError) -> Self {
        MacroblockError::FrameTooShort
    }
}

#[derive(Debug, Default)]
pub struct MacroblockHeader {
    mb_skip_coeff: bool,
    is_inter_mb: bool,
    mv_mode: Option<()>,
    intra_y_mode: Option<IntraMBMode>,
    sub_modes: Option<[[IntraBMode; 4]; 4]>,
    intra_uv_mode: Option<IntraMBMode>,
}

impl MacroblockHeader {
    fn parse<'a, 'b>(
        blocks: &mut Vec<Macroblock>,
        frame: &VP8FrameHeader,
        bd: &mut BoolDecoder<'a, 'b>,
    ) -> Result<Self> {
        let mut mb = MacroblockHeader::default();

        let index = blocks.len();
        let mb_width = frame.mb_width as usize;

        let top = if index >= mb_width {
            Some(index - mb_width)
        } else {
            None
        };
        let left = if (index % mb_width) != 0 {
            Some(index - 1)
        } else {
            None
        };

        if let Some(true) = frame.update_mb_segmentation_map {
            unimplemented!("Segmentation is not yet implemented");
        }

        mb.mb_skip_coeff = if let Some(p) = frame.prob_skip_false {
            bd.read_bool(p)? != 0
        } else {
            false
        };

        mb.is_inter_mb = if !frame.is_key {
            unimplemented!("Inter frames not implemented");
        } else {
            false
        };

        if mb.is_inter_mb {
            unimplemented!()
        } else {
            // Y (luma) intra mode
            let intra_y_mode = bd
                .read_treed(&KF_YMODE_TREE, &KF_YMODE_PROB)
                .map(IntraMBMode::from_repr)?
                .unwrap();

            // If BPred, decode 4x4 sub-modes using neighbour contexts from `blocks`
            let sub_modes = if intra_y_mode == IntraMBMode::BPred {
                let mut sub_modes = [[IntraBMode::BDcPred; 4]; 4];

                for y in 0..4 {
                    for x in 0..4 {
                        let above = if y > 0 {
                            sub_modes[y - 1][x]
                        } else {
                            top.and_then(|t| blocks[t].header.sub_modes.as_ref().map(|m| m[3][x]))
                                .unwrap_or(IntraBMode::BDcPred)
                        };

                        let left_ctx = if x > 0 {
                            sub_modes[y][x - 1]
                        } else {
                            left.and_then(|l| blocks[l].header.sub_modes.as_ref().map(|m| m[y][3]))
                                .unwrap_or(IntraBMode::BDcPred)
                        };

                        let prob_table = &KF_BMODE_PROB[above as usize][left_ctx as usize];
                        let intra_b_mode = bd
                            .read_treed(&BMODE_TREE, prob_table)
                            .map(IntraBMode::from_repr)?
                            .unwrap();

                        sub_modes[y][x] = intra_b_mode;
                    }
                }

                Some(sub_modes)
            } else {
                None
            };

            let intra_uv_mode = bd
                .read_treed(&UV_MODE_TREE, &KF_UV_MODE_PROB)
                .map(IntraMBMode::from_repr)?
                .unwrap();

            mb.intra_y_mode = Some(intra_y_mode);
            mb.sub_modes = sub_modes;
            mb.intra_uv_mode = Some(intra_uv_mode);
        }

        Ok(mb)
    }
}

const PCAT1: [u8; 1] = [159];
const PCAT2: [u8; 2] = [165, 145];
const PCAT3: [u8; 3] = [173, 148, 140];
const PCAT4: [u8; 4] = [176, 155, 140, 135];
const PCAT5: [u8; 5] = [180, 157, 141, 134, 130];
const PCAT6: [u8; 11] = [254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129];

const COEFF_BANDS: [usize; 16] = [0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7];
const CATEGORY_BASE: [i32; 6] = [5, 7, 11, 19, 35, 67];

#[derive(Debug, PartialEq, Eq, FromRepr)]
#[repr(i8)]
enum Token {
    Dct0 = 0,     /* value 0 */
    Dct1 = 1,     /* 1 */
    Dct2 = 2,     /* 2 */
    Dct3 = 3,     /* 3 */
    Dct4 = 4,     /* 4 */
    DctCat1 = 5,  /* range 5 - 6  (size 2) */
    DctCat2 = 6,  /* 7 - 10   (4) */
    DctCat3 = 7,  /* 11 - 18  (8) */
    DctCat4 = 8,  /* 19 - 34  (16) */
    DctCat5 = 9,  /* 35 - 66  (32) */
    DctCat6 = 10, /* 67 - 2048  (1982) */
    DctEob = 11,  /* end of block */
}

impl Token {
    pub const NUM_DCT_TOKENS: usize = 12;

    pub fn pcat(&self) -> Option<&'static [u8]> {
        match self {
            Token::DctCat1 => Some(&PCAT1),
            Token::DctCat2 => Some(&PCAT2),
            Token::DctCat3 => Some(&PCAT3),
            Token::DctCat4 => Some(&PCAT4),
            Token::DctCat5 => Some(&PCAT5),
            Token::DctCat6 => Some(&PCAT6),
            _ => None,
        }
    }
}

#[rustfmt::skip]
const COEFF_TREE: [i8; 2 * (Token::NUM_DCT_TOKENS - 1)] = {
    use Token::*;
    [
        -(DctEob as i8), 2,
        -(Dct0 as i8), 4,
        -(Dct1 as i8), 6, 8, 12,
        -(Dct2 as i8), 10,
        -(Dct3 as i8),
        -(Dct4 as i8), 14, 16,
        -(DctCat1 as i8),
        -(DctCat2 as i8), 18, 20,
        -(DctCat3 as i8),
        -(DctCat4 as i8),
        -(DctCat5 as i8),
        -(DctCat6 as i8),
    ]
};

#[rustfmt::skip]
const COEFF_TREE_NOEOB: [i8; 2 * (Token::NUM_DCT_TOKENS - 2)] = {
    use Token::*;
    [
        -(Dct0 as i8), 2,
        -(Dct1 as i8), 4, 6, 10,
        -(Dct2 as i8), 8,
        -(Dct3 as i8),
        -(Dct4 as i8), 12, 14,
        -(DctCat1 as i8),
        -(DctCat2 as i8), 16, 18,
        -(DctCat3 as i8),
        -(DctCat4 as i8),
        -(DctCat5 as i8),
        -(DctCat6 as i8),
    ]
};

const ZIGZAG: [u8; 16] = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];

#[derive(Default)]
pub struct HasCoeffMap {
    y: Vec<Vec<[bool; 16]>>,
    u: Vec<Vec<[bool; 4]>>,
    v: Vec<Vec<[bool; 4]>>,
    y2: Vec<Vec<bool>>,
}

#[derive(PartialEq, Eq, Clone, Copy)]
pub enum Plane {
    Y,
    U,
    V,
    Y2,
}

impl HasCoeffMap {
    pub fn new(mb_height: u16, mb_width: u16) -> Self {
        let mb_height = mb_height as usize;
        let mb_width = mb_width as usize;
        Self {
            y: vec![vec![[false; 16]; mb_width]; mb_height],
            u: vec![vec![[false; 4]; mb_width]; mb_height],
            v: vec![vec![[false; 4]; mb_width]; mb_height],
            y2: vec![vec![false; mb_width]; mb_height],
        }
    }

    pub fn get(&self, plane: Plane, row: usize, col: usize, block_idx: usize) -> bool {
        match plane {
            Plane::Y => self.y[row][col][block_idx],
            Plane::Y2 => self.y2[row][col],
            Plane::U => self.u[row][col][block_idx],
            Plane::V => self.v[row][col][block_idx],
        }
    }

    pub fn set(&mut self, plane: Plane, row: usize, col: usize, block_idx: usize, val: bool) {
        match plane {
            Plane::Y => self.y[row][col][block_idx] = val,
            Plane::Y2 => self.y2[row][col] = val,
            Plane::U => self.u[row][col][block_idx] = val,
            Plane::V => self.v[row][col][block_idx] = val,
        }
    }
}

fn get_left_neighbor(
    plane: Plane,
    row: usize,
    col: usize,
    block: usize,
) -> Option<(usize, usize, usize)> {
    if plane == Plane::Y {
        let bx = block % 4;
        let by = block / 4;
        if bx > 0 {
            Some((row, col, block - 1))
        } else if col > 0 {
            Some((row, col - 1, by * 4 + 3))
        } else {
            None
        }
    } else if plane == Plane::U || plane == Plane::V {
        if block % 2 == 1 {
            Some((row, col, block - 1))
        } else if col > 0 {
            Some((row, col - 1, block + 1))
        } else {
            None
        }
    } else {
        None
    }
}

fn get_above_neighbor(
    plane: Plane,
    row: usize,
    col: usize,
    block: usize,
) -> Option<(usize, usize, usize)> {
    if plane == Plane::Y {
        let bx = block % 4;
        let by = block / 4;
        if by > 0 {
            Some((row, col, block - 4))
        } else if row > 0 {
            Some((row - 1, col, 12 + bx))
        } else {
            None
        }
    } else if plane == Plane::U || plane == Plane::V {
        if block < 2 {
            if row > 0 {
                Some((row - 1, col, block + 2))
            } else {
                None
            }
        } else {
            Some((row, col, block - 2))
        }
    } else {
        None
    }
}

#[derive(Debug)]
pub struct ResidualBlock([i32; 16]);

impl ResidualBlock {
    pub fn parse<'a, 'b>(
        p: usize,
        plane: Plane,
        mb_row: usize,
        mb_col: usize,
        block_idx: usize,
        coeff_probs: &[[[[u8; 11]; 3]; 8]; 4],
        dcq: i16,
        acq: i16,
        has_coeff_map: &mut HasCoeffMap,
        bd: &mut BoolDecoder<'a, 'b>,
    ) -> Result<(Self, bool)> {
        let mut block = [0i32; 16];
        let mut has_coeff = false;
        let mut skip = false;
        let mut ctx = 0;

        if let Some((nb_row, nb_col, nb_idx)) = get_left_neighbor(plane, mb_row, mb_col, block_idx)
        {
            if has_coeff_map.get(plane, nb_row, nb_col, nb_idx) {
                ctx += 1;
            }
        }

        if let Some((nb_row, nb_col, nb_idx)) = get_above_neighbor(plane, mb_row, mb_col, block_idx)
        {
            if has_coeff_map.get(plane, nb_row, nb_col, nb_idx) {
                ctx += 1;
            }
        }

        let first_coeff = if p == 0 { 1 } else { 0 };

        for i in first_coeff..16 {
            let band = COEFF_BANDS[i];
            let probs = &coeff_probs[p][band][ctx];

            let token_repr = if skip {
                bd.read_treed(&COEFF_TREE_NOEOB, &probs[1..])?
            } else {
                bd.read_treed(&COEFF_TREE, probs)?
            };

            let token = Token::from_repr(token_repr).unwrap();

            if let Token::DctEob = token {
                break;
            }

            let mut abs_value: i32 = match token {
                Token::Dct0 => {
                    skip = true;
                    has_coeff = true;
                    ctx = 0;
                    continue;
                }
                Token::Dct1 => 1,
                Token::Dct2 => 2,
                Token::Dct3 => 3,
                Token::Dct4 => 4,
                Token::DctCat1
                | Token::DctCat2
                | Token::DctCat3
                | Token::DctCat4
                | Token::DctCat5
                | Token::DctCat6 => {
                    let probs = token.pcat().unwrap();
                    let extra = Self::dct_extra(probs, bd)?;
                    CATEGORY_BASE[token as usize - Token::DctCat1 as usize] + extra as i32
                }
                _ => unreachable!(),
            };

            has_coeff = true;
            skip = false;

            ctx = match abs_value {
                0 => 0,
                1 => 1,
                _ => 2,
            };

            let sign = bd.read_bool(128)?;
            if sign != 0 {
                abs_value = -abs_value;
            }

            let zigzag = ZIGZAG[i];
            block[zigzag as usize] = abs_value * if zigzag == 0 { dcq as i32 } else { acq as i32 };
        }

        has_coeff_map.set(plane, mb_row, mb_col, block_idx, has_coeff);

        Ok((Self(block), has_coeff))
    }

    fn dct_extra<'a, 'b>(probs: &[u8], bd: &mut BoolDecoder<'a, 'b>) -> Result<u32> {
        let mut v = 0u32;
        for &p in probs {
            v = (v << 1) | (bd.read_bool(p)? as u32);
        }
        Ok(v)
    }
}

#[derive(Debug)]
pub struct Tokens(Vec<ResidualBlock>);

impl Tokens {
    fn parse<'a, 'b>(
        (mb_row, mb_col, block): (u16, u16, &MacroblockHeader),
        frame: &VP8FrameHeader,
        has_coeff_map: &mut HasCoeffMap,
        bd: &mut BoolDecoder<'a, 'b>,
    ) -> Result<Self> {
        let mut residuals: Vec<ResidualBlock> = Vec::new();
        let mut y2_has_coeff = false;

        if (block.is_inter_mb && {
            #[allow(unreachable_code)]
            {
                block.mv_mode != unimplemented!("SPLITMV")
            }
        }) || (!block.is_inter_mb
            && block
                .intra_y_mode
                .as_ref()
                .map(|m| *m != IntraMBMode::BPred)
                .unwrap_or(false))
        {
            let (residual, has_coeff) = ResidualBlock::parse(
                1,
                Plane::Y2,
                mb_row as usize,
                mb_col as usize,
                0, // only 1 Y2 block
                &frame.coeff_probs,
                frame.y2dc,
                frame.y2ac,
                has_coeff_map,
                bd,
            )?;
            residuals.push(residual);
            y2_has_coeff = has_coeff;
        }
        for i in 0..16 {
            let plane = if y2_has_coeff { 0 } else { 3 };
            let (residual, _) = ResidualBlock::parse(
                plane,
                Plane::Y,
                mb_row as usize,
                mb_col as usize,
                i,
                &frame.coeff_probs,
                frame.ydc,
                frame.yac,
                has_coeff_map,
                bd,
            )?;
            residuals.push(residual);
        }

        for plane in [Plane::U, Plane::V] {
            for i in 0..4 {
                let (residual, _) = ResidualBlock::parse(
                    2,
                    plane,
                    mb_row as usize,
                    mb_col as usize,
                    i,
                    &frame.coeff_probs,
                    frame.uvdc,
                    frame.uvac,
                    has_coeff_map,
                    bd,
                )?;
                residuals.push(residual);
            }
        }

        Ok(Self(residuals))
    }
}

#[derive(Debug)]
pub struct Macroblock {
    header: MacroblockHeader,
    residuals: Option<Tokens>,
}

impl Macroblock {
    pub fn parse<'a, 'b>(
        frame: &VP8FrameHeader,
        bd: &mut BoolDecoder<'a, 'b>,
        residual_data: &'b [u8],
    ) -> Result<Vec<Self>> {
        if frame.num_partitions > 1 {
            unimplemented!();
        }

        let mut blocks = Vec::new();
        let mut residual_br = BitReader::new(residual_data);
        let mut residual_bd = BoolDecoder::new(&mut residual_br)?;
        let mut has_coeff_map = HasCoeffMap::new(frame.mb_height, frame.mb_width);

        for i in 0..frame.mb_height {
            for j in 0..frame.mb_width {
                let header = MacroblockHeader::parse(&mut blocks, frame, bd)?;
                let residuals = if !header.mb_skip_coeff {
                    Some(
                        Tokens::parse((i, j, &header), frame, &mut has_coeff_map, &mut residual_bd)
                            .inspect_err(|e| panic!("i: {i}, j: {j}, e: {e:?}"))?,
                    )
                } else {
                    None
                };
                // println!("Header: {header:?}\nResiduals: {residuals:?}");
                blocks.push(Macroblock { header, residuals });
            }
        }
        // println!("BD: {residual_bd:?}");
        Ok(blocks)
    }
}
