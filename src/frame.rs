use strum::Display;

use crate::{
    bit::{BitError, BitReader, BoolDecoder},
    macroblock::{Macroblock, MacroblockError},
    tables::{AC_QUANT, COEFF_UPDATE_PROBS, DC_QUANT, DEFAULT_COEFF_PROBS},
};

#[derive(Debug, Display)]
pub enum VP8FrameError {
    FrameTooShort,
    InvalidStartCode,
}

impl From<MacroblockError> for VP8FrameError {
    fn from(_: MacroblockError) -> Self {
        VP8FrameError::FrameTooShort
    }
}

const MAX_REF_LF_DELTAS: usize = 4;
const MAX_MODE_LF_DELTAS: usize = 4;

#[derive(Debug)]
pub struct VP8FrameHeader {
    // Basic frame info
    pub is_key: bool,
    pub version: u8,
    pub show_frame: bool,
    pub partition0_len: usize,

    // Frame size
    pub width: u16,
    pub height: u16,
    pub h_scale: u8,
    pub v_scale: u8,
    pub mb_width: u16,
    pub mb_height: u16,

    // Segment / color info
    pub clamping: Option<bool>, // Only present for keyframes
    pub segmentation_enabled: bool,
    pub update_mb_segmentation_map: Option<bool>,

    // Loop filter
    pub filter_type: u8,
    pub loop_filter_level: u8,
    pub sharpness_level: u8,
    pub loop_filter_adj_enable: bool,
    pub ref_lf_deltas: [i8; MAX_REF_LF_DELTAS],
    pub mode_lf_deltas: [i8; MAX_MODE_LF_DELTAS],

    // Token partitions
    pub num_partitions: u8,

    // Dequantization indices
    pub ydc: i16,
    pub yac: i16,
    pub y2dc: i16,
    pub y2ac: i16,
    pub uvdc: i16,
    pub uvac: i16,

    // Refresh Golden Frame and Altref Frame
    pub refresh_entropy_probs: bool,

    // DCT coefficient probabilities
    pub coeff_probs: [[[[u8; 11]; 3]; 8]; 4],

    // Refresh / reference frame flags
    pub refresh_golden_frame: Option<bool>,
    pub refresh_altref_frame: Option<bool>,
    pub golden_frame_copy: Option<u8>, // 0=none,1=last,2=altref
    pub altref_frame_copy: Option<u8>, // 0=none,1=last,2=golden
    pub ref_frame_sign_bias_golden: Option<bool>,
    pub ref_frame_sign_bias_altref: Option<bool>,
    pub refresh_last_frame: Option<bool>,

    // Remaining data
    pub mb_no_skip_coeff: bool,
    pub prob_skip_false: Option<u8>,
}

#[derive(Debug)]
pub struct VP8Frame {
    pub header: VP8FrameHeader,
    pub macroblocks: Vec<Macroblock>,
}

impl VP8Frame {
    pub fn parse<'a, 'b>(br: &'a mut BitReader<'b>) -> Result<Self, VP8FrameError> {
        let b0 = br.read_byte()?;
        let b1 = br.read_byte()?;
        let b2 = br.read_byte()?;

        let is_key = (b0 & 1) == 0;
        let version = (b0 >> 1) & 0b111;
        assert_eq!(version, 0, "Unsupported VP8 version");

        let show_frame = (b0 >> 4) & 1 != 0;
        let partition0_len =
            ((b0 as usize | ((b1 as usize) << 8) | ((b2 as usize) << 16)) >> 5) & 0x7FFFF;

        // if partition0_len > data.len() + 3 {
        //     return Err(VP8FrameHeaderError::FrameTooShort);
        // }

        if !is_key {
            unimplemented!("Inter frames are not supported yet");
        }

        let start_code = br.read_bytes()?;
        if start_code != [0x9D, 0x01, 0x2A] {
            return Err(VP8FrameError::InvalidStartCode);
        }

        let raw_width = u16::from_le_bytes(br.read_bytes::<2>()?.try_into().unwrap());
        let raw_height = u16::from_le_bytes(br.read_bytes::<2>()?.try_into().unwrap());
        let width = (raw_width & 0x3FFF) as u16;
        let h_scale = (raw_width >> 14) as u8;
        let height = (raw_height & 0x3FFF) as u16;
        let v_scale = (raw_height >> 14) as u8;

        let mb_width = (width + 15) / 16;
        let mb_height = (height + 15) / 16;

        // TODO: use a raw new bit reader for better bounderies
        let data = br.data;
        let mut bd = BoolDecoder::new(br)?;

        let clamping = if is_key {
            let color_space = bd.read_flag()?;
            assert_eq!(color_space, 0, "Unsupported color space");
            let clamping = bd.read_flag()? == 0;
            Some(clamping)
        } else {
            None
        };

        let segmentation_enabled = bd.read_flag()? != 0;
        if segmentation_enabled {
            unimplemented!("Segment based adjustments are not supported");
        }

        let filter_type = bd.read_flag()?;
        let loop_filter_level = bd.read_literal(6)? as u8;
        let sharpness_level = bd.read_literal(3)? as u8;

        let loop_filter_adj_enable = bd.read_flag()? != 0;
        let mut ref_lf_deltas = [0i8; MAX_REF_LF_DELTAS];
        let mut mode_lf_deltas = [0i8; MAX_MODE_LF_DELTAS];
        if loop_filter_adj_enable {
            let mode_ref_lf_delta_update = bd.read_flag()? != 0;
            if mode_ref_lf_delta_update {
                for delta in ref_lf_deltas.iter_mut() {
                    let ref_frame_delta_update_flag = bd.read_flag()? != 0;
                    if ref_frame_delta_update_flag {
                        let magnitude = bd.read_literal(6)? as i8;
                        let sign = bd.read_flag()? != 0;
                        *delta = if sign { -magnitude } else { magnitude };
                    }
                }

                for delta in mode_lf_deltas.iter_mut() {
                    let mb_mode_delta_update_flag = bd.read_flag()? != 0;
                    if mb_mode_delta_update_flag {
                        let magnitude = bd.read_literal(6)? as i8;
                        let sign = bd.read_flag()? != 0;
                        *delta = if sign { -magnitude } else { magnitude };
                    }
                }
            }
        }

        let log2_nbd_of_dct_partitions = bd.read_literal(2)? as u8;
        let num_partitions = match log2_nbd_of_dct_partitions {
            0b00 => 1,
            0b01 => 2,
            0b10 => 4,
            0b11 => 8,
            _ => unreachable!(),
        };

        fn read_delta(bd: &mut BoolDecoder) -> Result<Option<i8>, BitError> {
            Ok(if bd.read_flag()? != 0 {
                let magnitude = bd.read_literal(4)? as i8;
                let sign = bd.read_flag()? != 0;
                Some(if sign { -magnitude } else { magnitude })
            } else {
                None
            })
        }

        let yac_qi = bd.read_literal(7)? as u8;
        let ydc_delta = read_delta(&mut bd)?.unwrap_or(0);
        let y2dc_delta = read_delta(&mut bd)?.unwrap_or(0);
        let y2ac_delta = read_delta(&mut bd)?.unwrap_or(0);
        let uvdc_delta = read_delta(&mut bd)?.unwrap_or(0);
        let uvac_delta = read_delta(&mut bd)?.unwrap_or(0);

        fn dc_quant(index: i32) -> i16 {
            DC_QUANT[index.clamp(0, 127) as usize]
        }

        fn ac_quant(index: i32) -> i16 {
            AC_QUANT[index.clamp(0, 127) as usize]
        }

        let ydc = dc_quant(yac_qi as i32 + ydc_delta as i32);
        let yac = ac_quant(yac_qi as i32);

        let y2dc = dc_quant(yac_qi as i32 + y2dc_delta as i32) * 2;
        // intermediate result (max`284*155`) can be larger than the `i16` range.
        let y2ac = (i32::from(ac_quant(yac_qi as i32 + y2ac_delta as i32)) * 155 / 100) as i16;

        let uvdc = dc_quant(yac_qi as i32 + uvdc_delta as i32).max(8);
        let uvac = ac_quant(yac_qi as i32 + uvac_delta as i32).min(132);

        let refresh_entropy_probs;
        if is_key {
            refresh_entropy_probs = bd.read_flag()? != 0;
        } else {
            unimplemented!("Inter frames are not yet supported");
        }

        let mut coeff_probs = DEFAULT_COEFF_PROBS;
        for (i, plane) in coeff_probs.iter_mut().enumerate() {
            for (j, band) in plane.iter_mut().enumerate() {
                for (k, context) in band.iter_mut().enumerate() {
                    for (t, prob) in context.iter_mut().enumerate() {
                        if bd.read_bool(COEFF_UPDATE_PROBS[i][j][k][t])? != 0 {
                            *prob = bd.read_literal(8).unwrap() as u8;
                        }
                    }
                }
            }
        }

        let mb_no_skip_coeff = bd.read_flag()? != 0;
        let prob_skip_false = if mb_no_skip_coeff {
            Some(bd.read_literal(8)? as u8)
        } else {
            None
        };

        if !is_key {
            unimplemented!("Inter frames are not yet supported");
        }

        let header = VP8FrameHeader {
            is_key,
            version,
            show_frame,
            partition0_len,
            width,
            height,
            h_scale,
            v_scale,
            mb_width,
            mb_height,
            clamping,
            segmentation_enabled,
            update_mb_segmentation_map: None,
            filter_type,
            loop_filter_level,
            sharpness_level,
            loop_filter_adj_enable,
            ref_lf_deltas,
            mode_lf_deltas,
            num_partitions,
            yac,
            ydc,
            y2dc,
            y2ac,
            uvdc,
            uvac,
            refresh_entropy_probs,
            coeff_probs,
            refresh_golden_frame: None,
            refresh_altref_frame: None,
            golden_frame_copy: None,
            altref_frame_copy: None,
            ref_frame_sign_bias_golden: None,
            ref_frame_sign_bias_altref: None,
            refresh_last_frame: None,
            mb_no_skip_coeff,
            prob_skip_false,
        };

        let offset = partition0_len + 10;
        let macroblocks = Macroblock::parse(&header, &mut bd, &data[offset..])?;

        Ok(Self {
            header,
            macroblocks,
        })
    }
}

impl From<BitError> for VP8FrameError {
    fn from(_: BitError) -> Self {
        VP8FrameError::FrameTooShort
    }
}
