//! This module implements the macroblock parsing logic.
//!
//! It handles the parsing of macroblocks from token data, including
//! intra-prediction, token decoding, and color space conversion.
//! The primary entry point is the `MacroblockHeader::parse` method.

use strum::FromRepr;

use crate::{
    bit::{BitError, BitReader, BoolDecoder},
    frame::VP8FrameHeader,
    tables::KF_BMODE_PROB,
    util::{vp8_idct4x4, vp8_iwht4x4},
};

// TODO: make an enum for each plane
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromRepr)]
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

impl TryInto<IntraBMode> for IntraMBMode {
    type Error = ();

    fn try_into(self) -> std::result::Result<IntraBMode, Self::Error> {
        match self {
            IntraMBMode::DcPred => Ok(IntraBMode::BDcPred),
            IntraMBMode::VPred => Ok(IntraBMode::BVePred),
            IntraMBMode::HPred => Ok(IntraBMode::BHePred),
            IntraMBMode::TmPred => Ok(IntraBMode::BTmPred),
            IntraMBMode::BPred => Err(()),
        }
    }
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
    pub mb_skip_coeff: bool,
    pub is_inter_mb: bool,
    pub mv_mode: Option<()>,
    pub intra_y_mode: Option<IntraMBMode>,
    pub sub_modes: Option<[[IntraBMode; 4]; 4]>,
    pub intra_uv_mode: Option<IntraMBMode>,
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
            let sub_modes =
                if intra_y_mode == IntraMBMode::BPred {
                    let mut sub_modes = [[IntraBMode::BDcPred; 4]; 4];

                    for y in 0..4 {
                        for x in 0..4 {
                            let above = if y > 0 {
                                sub_modes[y - 1][x]
                            } else {
                                top.map(|t| {
                                    let h = &blocks[t].header;
                                    h.sub_modes.as_ref().map(|m| m[3][x]).unwrap_or_else(|| {
                                        h.intra_y_mode.unwrap().try_into().unwrap()
                                    })
                                })
                                .unwrap_or(IntraBMode::BDcPred)
                            };

                            let left_ctx = if x > 0 {
                                sub_modes[y][x - 1]
                            } else {
                                left.map(|l| {
                                    let h = &blocks[l].header;
                                    h.sub_modes.as_ref().map(|m| m[y][3]).unwrap_or_else(|| {
                                        h.intra_y_mode.unwrap().try_into().unwrap()
                                    })
                                })
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

#[derive(PartialEq, Eq, Clone, Copy)]
pub enum Plane {
    Y2,
    Y(bool),
    U,
    V,
}

impl Plane {
    pub fn first_coeff(&self) -> usize {
        match self {
            Plane::Y(true) => 1,
            _ => 0,
        }
    }
    pub fn index(&self) -> usize {
        match self {
            Plane::Y(true) => 0,
            Plane::Y2 => 1,
            Plane::U => 2,
            Plane::V => 2,
            Plane::Y(false) => 3,
        }
    }
}

#[derive(Debug, Clone)]
pub struct MayBeTokens<'a, const N: usize>(pub Option<&'a [Tokens; N]>);

impl<'a, const N: usize> MayBeTokens<'a, N> {
    pub fn slice<const M: usize>(&self, offset: usize) -> MayBeTokens<'a, M> {
        if let Some(slice) = self.0 {
            let subslice = &slice[offset..offset + M];
            MayBeTokens(Some(subslice.try_into().unwrap()))
        } else {
            MayBeTokens(None)
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct Tokens(pub [i32; 16]);

impl Tokens {
    pub fn parse<'a, 'b>(
        plane: Plane,
        coeff_probs: &[[[[u8; 11]; 3]; 8]; 4],
        dcq: i16,
        acq: i16,
        mut complexity: usize,
        bd: &mut BoolDecoder<'a, 'b>,
    ) -> Result<(Self, bool)> {
        let mut block = [0i32; 16];
        let mut has_coeff = false;
        let mut skip = false;

        for i in plane.first_coeff()..16 {
            let band = COEFF_BANDS[i];
            let probs = &coeff_probs[plane.index()][band][complexity];

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
                    complexity = 0;
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

            complexity = match abs_value {
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

#[derive(Debug, Clone)]
pub struct Residuals {
    pub luma: [Tokens; 16],
    pub chroma: [[Tokens; 4]; 2],
}

impl Residuals {
    fn parse<'a, 'b>(
        (_, mb_col, block): (u16, u16, &MacroblockHeader),
        frame: &VP8FrameHeader,
        has_coeff_vec: &mut Vec<(bool, [bool; 4], [[bool; 2]; 2])>,
        bd: &mut BoolDecoder<'a, 'b>,
    ) -> Result<Self> {
        let mbx = mb_col as usize + 1; // the index of the top block [[left], [top0] ...]

        let mut y2_has_coeff = false;
        let mut luma_dc = None;

        if (block.is_inter_mb && {
            #[allow(unreachable_code)]
            {
                block.mv_mode != unimplemented!("SPLITMV")
            }
        }) || (!block.is_inter_mb
            && block
                .intra_y_mode
                .as_ref()
                .map(|&m| m != IntraMBMode::BPred)
                .unwrap_or(false))
        {
            let mut complexity = 0;
            if has_coeff_vec[mbx].0 {
                complexity += 1;
            }
            if has_coeff_vec[0].0 {
                complexity += 1;
            }

            let (mut residual, has_coeff) = Tokens::parse(
                Plane::Y2,
                &frame.coeff_probs,
                frame.y2dc,
                frame.y2ac,
                complexity,
                bd,
            )?;

            vp8_iwht4x4(&mut residual.0);
            luma_dc = Some(residual);
            y2_has_coeff = true; // has_coeff; // Pin it to true
            has_coeff_vec[mbx].0 = has_coeff;
            has_coeff_vec[0].0 = has_coeff;
        }

        let mut luma: [Tokens; 16] = std::array::from_fn(|_| Default::default());
        for i in 0..4 {
            let mut left = has_coeff_vec[0].1[i];
            for j in 0..4 {
                let mut complexity = 0;
                if has_coeff_vec[mbx].1[j] {
                    complexity += 1;
                }
                if left {
                    complexity += 1;
                }

                let (mut residual, has_coeff) = Tokens::parse(
                    Plane::Y(y2_has_coeff),
                    &frame.coeff_probs,
                    frame.ydc,
                    frame.yac,
                    complexity,
                    bd,
                )?;
                if let Some(ref luma_dc) = luma_dc {
                    residual.0[0] = luma_dc.0[i * 4 + j];
                }
                vp8_idct4x4(&mut residual.0);
                luma[i * 4 + j] = residual;
                has_coeff_vec[mbx].1[j] = has_coeff;
                left = has_coeff;
            }
            has_coeff_vec[0].1[i] = left;
        }

        let mut chroma: [[Tokens; 4]; 2] = std::array::from_fn(|_| Default::default());
        for (p, plane) in [Plane::U, Plane::V].into_iter().enumerate() {
            for i in 0..2 {
                let mut left = has_coeff_vec[0].2[p][i];
                for j in 0..2 {
                    let mut complexity = 0;
                    if has_coeff_vec[mbx].2[p][j] {
                        complexity += 1;
                    }
                    if left {
                        complexity += 1;
                    }

                    let (mut residual, has_coeff) = Tokens::parse(
                        plane,
                        &frame.coeff_probs,
                        frame.uvdc,
                        frame.uvac,
                        complexity,
                        bd,
                    )?;
                    vp8_idct4x4(&mut residual.0);
                    chroma[p][i * 2 + j] = residual;
                    has_coeff_vec[mbx].2[p][j] = has_coeff;
                    left = has_coeff;
                }
                has_coeff_vec[0].2[p][i] = left;
            }
        }

        Ok(Self { luma, chroma })
    }
}

#[derive(Debug)]
pub struct Residue(pub Option<Residuals>);

#[derive(Debug)]
pub struct Macroblock {
    pub pos: (u16, u16),
    pub header: MacroblockHeader,
    pub residue: Residue,
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
        let mut has_coeff_vec =
            vec![(false, [false; 4], [[false; 2]; 2]); frame.mb_width as usize + 1];
        let mut residual_br = BitReader::new(residual_data);
        let mut residual_bd = BoolDecoder::new(&mut residual_br)?;

        for i in 0..frame.mb_height {
            for j in 0..frame.mb_width {
                let header = MacroblockHeader::parse(&mut blocks, frame, bd)?;
                let residue = if !header.mb_skip_coeff {
                    let r = Residuals::parse(
                        (i, j, &header),
                        frame,
                        &mut has_coeff_vec,
                        &mut residual_bd,
                    )
                    .inspect_err(|e| panic!("i: {i}, j: {j}, e: {e:?}"))?;
                    Residue(Some(r))
                } else {
                    if let Some(IntraMBMode::BPred) = header.intra_y_mode {
                        has_coeff_vec[0].1 = Default::default();
                        has_coeff_vec[0].2 = Default::default();
                        has_coeff_vec[j as usize + 1].1 = Default::default();
                        has_coeff_vec[j as usize + 1].2 = Default::default();
                    } else {
                        has_coeff_vec[0] = Default::default();
                        has_coeff_vec[j as usize + 1] = Default::default();
                    }
                    Residue(None)
                };
                blocks.push(Macroblock {
                    pos: (j, i),
                    header,
                    residue,
                });
            }
            has_coeff_vec[0] = Default::default();
        }
        Ok(blocks)
    }
}
