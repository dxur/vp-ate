//! This module implements the VP8 decoding logic.
//!
//! It handles the reconstruction of video frames from macroblock data, including
//! intra-prediction, token decoding, and color space conversion.
//! The primary entry point is the `VP8Frame::decode` method.

use crate::frame::VP8Frame;
use crate::macroblock::{IntraBMode, IntraMBMode, Macroblock, MayBeTokens};
use crate::prediction::*;
use crate::util::{a_of, b_of, c_of, pack_color, yuv2rgb};

impl VP8Frame {
    pub fn decode(self, buf: &mut Vec<u32>) -> (usize, usize) {
        let mbw = self.header.mb_width as usize;
        let w = self.header.width as usize;
        let h = self.header.height as usize;

        buf.clear();
        buf.resize(w * h, 0x00808080); // 00YYUUVV

        let mut top: Option<([u8; 16], [[u8; 8]; 2])> = None;
        let mut left: Option<([u8; 16], [[u8; 8]; 2])> = None;
        let mut top_left: Option<(u8, [u8; 2])> = None;
        let mut top_right: Option<Option<[u8; 4]>> = None;

        for (i, row) in self.macroblocks.chunks(mbw).enumerate() {
            for (j, mb) in row.iter().enumerate() {
                // FIXME: for non standard resulotion this will be wrong, I suppose!
                Self::update_edges(
                    j,
                    i,
                    w,
                    buf,
                    &mut top,
                    &mut left,
                    &mut top_left,
                    &mut top_right,
                );
                let plane = mb.decode(&top, &left, &top_left, &top_right);
                Self::apply(j, i, w, plane, buf);
            }
        }

        // use std::io::Write;
        // let mut file = std::fs::File::create("framebuffer.ppm").unwrap();
        // write!(file, "P5\n{} {}\n255\n", w, h).unwrap();
        // let mut gray = Vec::with_capacity(buf.len());
        // for &px in buf.iter() {
        //     let y = a_of(px);
        //     gray.push(y);
        // }
        // file.write_all(&gray).unwrap();

        buf.iter_mut().for_each(yuv2rgb);

        // draw_mb_grid(w, h, 16, 16, 0x00FF0000, buf);

        (w, h)
    }

    fn update_edges(
        x: usize,
        y: usize,
        w: usize,
        buf: &[u32],
        top: &mut Option<([u8; 16], [[u8; 8]; 2])>,
        left: &mut Option<([u8; 16], [[u8; 8]; 2])>,
        top_left: &mut Option<(u8, [u8; 2])>,
        top_right: &mut Option<Option<[u8; 4]>>,
    ) {
        let i = y * 16 * w + x * 16;
        *top = if y == 0 {
            None
        } else {
            let mut luma = [0u8; 16];
            for (y, &c) in luma.iter_mut().zip(buf[i - w..].iter()) {
                *y = a_of(c);
            }
            let mut chroma = [[0u8; 8]; 2];
            let [ref mut cb, ref mut cr] = chroma;
            for ((u, v), &c) in cb
                .iter_mut()
                .zip(cr.iter_mut())
                .zip(buf[i - w..].iter().step_by(2))
            {
                *u = b_of(c);
                *v = c_of(c);
            }

            Some((luma, chroma))
        };

        *left = if x == 0 {
            None
        } else {
            let mut luma = [0u8; 16];
            for (y, &c) in luma.iter_mut().zip(buf[i - 1..].iter().step_by(w)) {
                *y = a_of(c);
            }
            let mut chroma = [[0u8; 8]; 2];
            let [ref mut cb, ref mut cr] = chroma;
            for ((u, v), &c) in cb
                .iter_mut()
                .zip(cr.iter_mut())
                .zip(buf[i - 1..].iter().step_by(2 * w))
            {
                *u = b_of(c);
                *v = c_of(c);
            }

            Some((luma, chroma))
        };

        *top_left = if x == 0 || y == 0 {
            None
        } else {
            let c = buf[i - w - 1];
            Some((a_of(c), [b_of(c), c_of(c)]))
        };

        *top_right = if (x + 1) * 16 + 4 >= w {
            if y == 0 { Some(None) } else { None }
        } else if y == 0 {
            Some(None)
        } else {
            let mut luma = [0u8; 4];
            for (y, &c) in luma.iter_mut().zip(buf[i + 16 - w..].iter()) {
                *y = a_of(c);
            }
            Some(Some(luma))
        };
    }

    fn apply(
        x: usize,
        y: usize,
        w: usize,
        plane: ([[u8; 16]; 16], [[[u8; 8]; 8]; 2]),
        buf: &mut [u32],
    ) {
        let (luma, chroma) = plane;
        for yy in 0..16 {
            for xx in 0..16 {
                let idx = (y * 16 + yy) * w + (x * 16 + xx);
                let y = luma[yy][xx];
                let u = chroma[0][yy / 2][xx / 2];
                let v = chroma[1][yy / 2][xx / 2];
                buf[idx] = pack_color(y, u, v);
            }
        }
    }
}

impl<'a, const N: usize, const M: usize> std::ops::Add<[[u8; M]; M]> for MayBeTokens<'a, N> {
    type Output = [[u8; M]; M];

    fn add(self, mut rhs: [[u8; M]; M]) -> Self::Output {
        assert!(M * M == 16 * N, "Dimension mismatch: M*M must equal 16*N");
        assert!(M % 4 == 0, "M must be a multiple of 4");

        if let MayBeTokens(Some(tokens)) = self {
            let blocks_per_row = M / 4;
            for (block_idx, token) in tokens.iter().enumerate() {
                let block_y = block_idx / blocks_per_row;
                let block_x = block_idx % blocks_per_row;

                for y in 0..4 {
                    for x in 0..4 {
                        let val = token.0[y * 4 + x];
                        let px = &mut rhs[block_y * 4 + y][block_x * 4 + x];
                        let sum = (*px as i32 + val).clamp(0, 255);
                        *px = sum as u8;
                    }
                }
            }
        }

        rhs
    }
}

impl Macroblock {
    pub fn decode(
        &self,
        top: &Option<([u8; 16], [[u8; 8]; 2])>,
        left: &Option<([u8; 16], [[u8; 8]; 2])>,
        top_left: &Option<(u8, [u8; 2])>,
        top_right: &Option<Option<[u8; 4]>>,
    ) -> ([[u8; 16]; 16], [[[u8; 8]; 8]; 2]) {
        let luma = self.predict_luma(
            &top.map(|v| v.0),
            &left.map(|v| v.0),
            &top_left.map(|v| v.0),
            top_right,
        );

        // (luma, [[[128u8; 8]; 8]; 2])

        let chroma = self.predict_chroma(
            &top.map(|v| v.1),
            &left.map(|v| v.1),
            &top_left.map(|v| v.1),
        );

        // ([[128u8; 16]; 16], chroma)
        (luma, chroma)
    }

    fn predict_luma(
        &self,
        top: &Option<[u8; 16]>,
        left: &Option<[u8; 16]>,
        top_left: &Option<u8>,
        top_right: &Option<Option<[u8; 4]>>,
    ) -> [[u8; 16]; 16] {
        let r = MayBeTokens(self.residue.0.as_ref().map(|v| &v.luma));
        let mode = self
            .header
            .intra_y_mode
            .expect("Only intra mode supported for now");
        let block = match mode {
            IntraMBMode::DcPred => r + predict_dcpred(top, left),
            IntraMBMode::VPred => r + predict_vpred(top),
            IntraMBMode::HPred => r + predict_hpred(left),
            IntraMBMode::TmPred => r + predict_tmpred(top, left, top_left),
            IntraMBMode::BPred => self.b_pred(top, left, top_left, top_right),
        };
        // dump(&block);

        block
    }

    fn calc_edges(
        x: usize,
        y: usize,
        block: &[[u8; 16]; 16],
        top: &Option<[u8; 16]>,
        left: &Option<[u8; 16]>,
        top_left: &Option<u8>,
        top_right: &Option<Option<[u8; 4]>>,
    ) -> (
        Option<[u8; 4]>,
        Option<[u8; 4]>,
        Option<u8>,
        Option<[u8; 4]>,
    ) {
        (
            if y == 0 {
                top.map(|v| v[x * 4..x * 4 + 4].try_into().unwrap())
            } else {
                Some(block[y * 4 - 1][x * 4..x * 4 + 4].try_into().unwrap())
            },
            if x == 0 {
                left.map(|v| v[y * 4..y * 4 + 4].try_into().unwrap())
            } else {
                let mut l = [0u8; 4];
                block[y * 4..y * 4 + 4]
                    .iter()
                    .enumerate()
                    .for_each(|(i, r)| l[i] = r[x * 4 - 1]);
                Some(l)
            },
            if y == 0 && x == 0 {
                *top_left
            } else if y == 0 {
                top.map(|v| v[x * 4 - 1])
            } else if x == 0 {
                left.map(|v| v[y * 4 - 1])
            } else {
                Some(block[y * 4 - 1][x * 4 - 1])
            },
            // TEST: this should be tested further more
            if x == 3 {
                match top_right {
                    None => None,
                    Some(None) => Some([127; 4]),
                    Some(v) => *v,
                }
            } else {
                if y == 0 {
                    top.map(|v| v[(x + 1) * 4..(x + 1) * 4 + 4].try_into().unwrap())
                } else {
                    Some(
                        block[y * 4 - 1][(x + 1) * 4..(x + 1) * 4 + 4]
                            .try_into()
                            .unwrap(),
                    )
                }
            },
        )
    }

    fn apply_sub_block(x: usize, y: usize, sub_block: [[u8; 4]; 4], block: &mut [[u8; 16]; 16]) {
        for i in 0..4 {
            for j in 0..4 {
                block[y * 4 + i][x * 4 + j] = sub_block[i][j];
            }
        }
    }

    fn b_pred(
        &self,
        top: &Option<[u8; 16]>,
        left: &Option<[u8; 16]>,
        top_left: &Option<u8>,
        top_right: &Option<Option<[u8; 4]>>,
    ) -> [[u8; 16]; 16] {
        // FIXME: pass the other 4 pixels immediatly right to the top pixels on the same row
        // and pass the correct values in case of unavailable / edges blocks
        let r = MayBeTokens(self.residue.0.as_ref().map(|v| &v.luma));
        let mut block = [[128u8; 16]; 16];
        for (i, row) in self.header.sub_modes.as_ref().unwrap().iter().enumerate() {
            for (j, &mode) in row.iter().enumerate() {
                let (top, left, top_left, top_right) =
                    Self::calc_edges(j, i, &block, top, left, top_left, top_right);
                let prediction = Self::predict_4x4(mode, &top, &left, &top_left, &top_right);
                let sub_block = r.slice::<1>(i * 4 + j) + prediction;
                Self::apply_sub_block(j, i, sub_block, &mut block);
            }
        }
        block
    }

    fn predict_4x4(
        mode: IntraBMode,
        top: &Option<[u8; 4]>,
        left: &Option<[u8; 4]>,
        top_left: &Option<u8>,
        top_right: &Option<[u8; 4]>,
    ) -> [[u8; 4]; 4] {
        match mode {
            IntraBMode::BDcPred => predict_dcpred_avg(top, left),
            IntraBMode::BVePred => predict_vpred_avg(top, top_left, top_right),
            IntraBMode::BHePred => predict_hpred_avg(left, top_left),
            IntraBMode::BTmPred => predict_tmpred(top, left, top_left),
            IntraBMode::BLdPred => predict_bldpred(top, top_right),
            IntraBMode::BRdPred => predict_brdpred(top, left, top_left),
            IntraBMode::BVrPred => predict_bvrpred(top, left, top_left),
            IntraBMode::BVlPred => predict_bvlpred(top, top_right),
            IntraBMode::BHdPred => predict_bhdpred(top, left, top_left),
            IntraBMode::BHuPred => predict_bhupred(left),
        }
    }

    fn predict_chroma(
        &self,
        top: &Option<[[u8; 8]; 2]>,
        left: &Option<[[u8; 8]; 2]>,
        top_left: &Option<[u8; 2]>,
    ) -> [[[u8; 8]; 8]; 2] {
        let tu = &top.map(|v| v[0]);
        let tv = &top.map(|v| v[1]);
        let lu = &left.map(|v| v[0]);
        let lv = &left.map(|v| v[1]);
        let tlu = &top_left.map(|v| v[0]);
        let tlv = &top_left.map(|v| v[1]);
        let [ublock, vblock] = match self
            .header
            .intra_uv_mode
            .expect("Only intra mode supported for now")
        {
            IntraMBMode::DcPred => [predict_dcpred(tu, lu), predict_dcpred(tv, lv)],
            IntraMBMode::VPred => [predict_vpred(tu), predict_vpred(tv)],
            IntraMBMode::HPred => [predict_hpred(lu), predict_hpred(lv)],
            IntraMBMode::TmPred => [predict_tmpred(tu, lu, tlu), predict_tmpred(tv, lv, tlv)],
            _ => unreachable!(),
        };
        let ru = MayBeTokens(self.residue.0.as_ref().map(|v| &v.chroma[0]));
        let rv = MayBeTokens(self.residue.0.as_ref().map(|v| &v.chroma[1]));
        let ublock = ru + ublock;
        let vblock = rv + vblock;
        [ublock, vblock]
    }
}
