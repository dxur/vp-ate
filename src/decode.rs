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
    /// Decodes the VP8 frame into an RGB buffer.
    ///
    /// This method processes all macroblocks in the frame, applies intra-prediction,
    /// reconstructs the YUV color space, and converts to RGB format.
    ///
    /// # Arguments
    ///
    /// * `buf` - Mutable reference to a vector that will be filled with RGB pixel data
    ///
    /// # Returns
    ///
    /// A tuple containing the width and height of the decoded frame
    pub fn decode(&mut self, buf: &mut Vec<u32>) -> (usize, usize) {
        let mbw = self.header.mb_width as usize;
        let w = self.header.width as usize;
        let h = self.header.height as usize;

        // Initialize buffer with default YUV values (00YYUUVV format)
        buf.clear();
        buf.resize(w * h, 0x00808080); // 00YYUUVV

        // Edge context for prediction
        let mut top: Option<([u8; 16], [[u8; 8]; 2])> = None;
        let mut left: Option<([u8; 16], [[u8; 8]; 2])> = None;
        let mut top_left: Option<(u8, [u8; 2])> = None;
        let mut top_right: Option<Option<[u8; 4]>> = None;

        // Process macroblocks row by row
        for (i, row) in self.macroblocks.chunks(mbw).enumerate() {
            for (j, mb) in row.iter().enumerate() {
                // FIXME: for non standard resulotion this will be wrong, I suppose!
                // Update edge contexts based on neighboring macroblocks
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
                // Decode the macroblock using edge contexts
                let (plane, residuals) =
                    mb.decode_with_residuals(&top, &left, &top_left, &top_right);

                // Update debug data
                let d = &mut self.debug_data[i * mbw + j];
                d.luma = residuals.0;
                d.chroma = residuals.1;
                d.y_pixels = plane.0;
                d.cb_pixels = plane.1[0];
                d.cr_pixels = plane.1[1];

                // Apply the decoded macroblock to the buffer
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

        // Convert from YUV to RGB color space
        buf.iter_mut().for_each(yuv2rgb);

        // draw_mb_grid(w, h, 16, 16, 0x00FF0000, buf);

        (w, h)
    }

    /// Updates the edge contexts for prediction based on neighboring macroblocks.
    ///
    /// This function extracts pixel values from already-decoded neighboring macroblocks
    /// to use as reference for predicting the current macroblock.
    ///
    /// # Arguments
    ///
    /// * `x` - Horizontal position of the macroblock (in macroblock units)
    /// * `y` - Vertical position of the macroblock (in macroblock units)
    /// * `w` - Width of the frame in pixels
    /// * `buf` - The current frame buffer containing decoded pixels
    /// * `top` - Mutable reference to top edge context (luma and chroma)
    /// * `left` - Mutable reference to left edge context (luma and chroma)
    /// * `top_left` - Mutable reference to top-left corner pixel
    /// * `top_right` - Mutable reference to top-right edge context
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
        // Calculate starting index of current macroblock
        let i = y * 16 * w + x * 16;

        // Extract top edge pixels (16 luma, 8 chroma per channel)
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

        // Extract left edge pixels (16 luma, 8 chroma per channel)
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

        // Extract top-left corner pixel (1 luma, 2 chroma)
        *top_left = if x == 0 || y == 0 {
            None
        } else {
            let c = buf[i - w - 1];
            Some((a_of(c), [b_of(c), c_of(c)]))
        };

        // Extract top-right edge pixels (4 luma pixels)
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

    /// Applies a decoded macroblock plane to the output buffer.
    ///
    /// Converts separate luma and chroma planes into packed YUV format
    /// and writes them to the appropriate position in the buffer.
    ///
    /// # Arguments
    ///
    /// * `x` - Horizontal position of the macroblock (in macroblock units)
    /// * `y` - Vertical position of the macroblock (in macroblock units)
    /// * `w` - Width of the frame in pixels
    /// * `plane` - The decoded macroblock data (luma and chroma planes)
    /// * `buf` - Mutable reference to the output buffer
    fn apply(
        x: usize,
        y: usize,
        w: usize,
        plane: ([[u8; 16]; 16], [[[u8; 8]; 8]; 2]),
        buf: &mut [u32],
    ) {
        let (luma, chroma) = plane;
        // Write each pixel of the 16x16 macroblock
        for yy in 0..16 {
            for xx in 0..16 {
                let idx = (y * 16 + yy) * w + (x * 16 + xx);
                let y = luma[yy][xx];
                // Chroma is subsampled 2x2, so divide coordinates by 2
                let u = chroma[0][yy / 2][xx / 2];
                let v = chroma[1][yy / 2][xx / 2];
                buf[idx] = pack_color(y, u, v);
            }
        }
    }
}

/// Implements addition of residual tokens to a prediction block.
///
/// This allows combining predicted pixel values with decoded residual coefficients
/// to produce the final reconstructed block.
impl<'a, const N: usize, const M: usize> std::ops::Add<[[u8; M]; M]> for MayBeTokens<'a, N> {
    type Output = [[u8; M]; M];

    /// Adds residual tokens to a prediction block.
    ///
    /// The residual tokens are organized in 4x4 sub-blocks and are added to
    /// the corresponding positions in the prediction block. Values are clamped
    /// to the valid range [0, 255].
    ///
    /// # Arguments
    ///
    /// * `rhs` - The prediction block to add residuals to
    ///
    /// # Returns
    ///
    /// The reconstructed block with residuals applied
    fn add(self, mut rhs: [[u8; M]; M]) -> Self::Output {
        assert!(M * M == 16 * N, "Dimension mismatch: M*M must equal 16*N");
        assert!(M % 4 == 0, "M must be a multiple of 4");

        if let MayBeTokens(Some(tokens)) = self {
            let blocks_per_row = M / 4;
            // Process each 4x4 sub-block
            for (block_idx, token) in tokens.iter().enumerate() {
                let block_y = block_idx / blocks_per_row;
                let block_x = block_idx % blocks_per_row;

                // Add residual to each pixel in the 4x4 block
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
    /// Decodes a macroblock using intra-prediction.
    ///
    /// Reconstructs both luma (brightness) and chroma (color) planes
    /// using edge contexts from neighboring macroblocks.
    ///
    /// # Arguments
    ///
    /// * `top` - Top edge context (luma and chroma)
    /// * `left` - Left edge context (luma and chroma)
    /// * `top_left` - Top-left corner pixel (luma and chroma)
    /// * `top_right` - Top-right edge context (luma only)
    ///
    /// # Returns
    ///
    /// A tuple containing the decoded luma plane (16x16) and chroma planes (8x8 each)
    pub fn decode(
        &self,
        top: &Option<([u8; 16], [[u8; 8]; 2])>,
        left: &Option<([u8; 16], [[u8; 8]; 2])>,
        top_left: &Option<(u8, [u8; 2])>,
        top_right: &Option<Option<[u8; 4]>>,
    ) -> ([[u8; 16]; 16], [[[u8; 8]; 8]; 2]) {
        self.decode_with_residuals(top, left, top_left, top_right).0
    }

    pub fn decode_with_residuals(
        &self,
        top: &Option<([u8; 16], [[u8; 8]; 2])>,
        left: &Option<([u8; 16], [[u8; 8]; 2])>,
        top_left: &Option<(u8, [u8; 2])>,
        top_right: &Option<Option<[u8; 4]>>,
    ) -> (
        ([[u8; 16]; 16], [[[u8; 8]; 8]; 2]),
        ([[u8; 16]; 16], [[[u8; 8]; 8]; 2]),
    ) {
        let (luma_pixels, luma_residuals) = self.predict_luma_with_residuals(
            &top.map(|v| v.0),
            &left.map(|v| v.0),
            &top_left.map(|v| v.0),
            top_right,
        );

        let (chroma_pixels, chroma_residuals) = self.predict_chroma_with_residuals(
            &top.map(|v| v.1),
            &left.map(|v| v.1),
            &top_left.map(|v| v.1),
        );

        (
            (luma_pixels, chroma_pixels),
            (luma_residuals, chroma_residuals),
        )
    }

    fn predict_luma_with_residuals(
        &self,
        top: &Option<[u8; 16]>,
        left: &Option<[u8; 16]>,
        top_left: &Option<u8>,
        top_right: &Option<Option<[u8; 4]>>,
    ) -> ([[u8; 16]; 16], [[u8; 16]; 16]) {
        let r = MayBeTokens(self.residue.0.as_ref().map(|v| &v.luma));
        let mode = self
            .header
            .intra_y_mode
            .expect("Only intra mode supported for now");

        let mut residuals = [[0u8; 16]; 16];
        if let Some(tokens) = r.0 {
            for i in 0..4 {
                for j in 0..4 {
                    let block = &tokens[i * 4 + j].0;
                    for y in 0..4 {
                        for x in 0..4 {
                            residuals[i * 4 + y][j * 4 + x] = block[y * 4 + x] as u8;
                        }
                    }
                }
            }
        }

        let prediction = match mode {
            IntraMBMode::DcPred => predict_dcpred(top, left),
            IntraMBMode::VPred => predict_vpred(top),
            IntraMBMode::HPred => predict_hpred(left),
            IntraMBMode::TmPred => predict_tmpred(top, left, top_left),
            IntraMBMode::BPred => self.b_pred(top, left, top_left, top_right),
        };

        (r + prediction, residuals)
    }

    fn predict_chroma_with_residuals(
        &self,
        top: &Option<[[u8; 8]; 2]>,
        left: &Option<[[u8; 8]; 2]>,
        top_left: &Option<[u8; 2]>,
    ) -> ([[[u8; 8]; 8]; 2], [[[u8; 8]; 8]; 2]) {
        let tu = &top.map(|v| v[0]);
        let tv = &top.map(|v| v[1]);
        let lu = &left.map(|v| v[0]);
        let lv = &left.map(|v| v[1]);
        let tlu = &top_left.map(|v| v[0]);
        let tlv = &top_left.map(|v| v[1]);

        let [upred, vpred] = match self
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

        let mut residuals = [[[0u8; 8]; 8]; 2];
        if let Some(tokens) = ru.0 {
            for i in 0..2 {
                for j in 0..2 {
                    let block = &tokens[i * 2 + j].0;
                    for y in 0..4 {
                        for x in 0..4 {
                            residuals[0][i * 4 + y][j * 4 + x] = block[y * 4 + x] as u8;
                        }
                    }
                }
            }
        }
        if let Some(tokens) = rv.0 {
            for i in 0..2 {
                for j in 0..2 {
                    let block = &tokens[i * 2 + j].0;
                    for y in 0..4 {
                        for x in 0..4 {
                            residuals[1][i * 4 + y][j * 4 + x] = block[y * 4 + x] as u8;
                        }
                    }
                }
            }
        }

        ([ru + upred, rv + vpred], residuals)
    }

    /// Predicts the luma (brightness) plane of a macroblock.
    ///
    /// Uses intra-prediction modes to generate predicted pixel values based on
    /// neighboring pixels, then adds residual coefficients to produce the final values.
    ///
    /// # Arguments
    ///
    /// * `top` - Top edge pixels (16 luma values)
    /// * `left` - Left edge pixels (16 luma values)
    /// * `top_left` - Top-left corner pixel
    /// * `top_right` - Top-right edge pixels (4 luma values)
    ///
    /// # Returns
    ///
    /// A 16x16 array of reconstructed luma values
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
        // Apply the appropriate prediction mode and add residuals
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

    /// Calculates edge contexts for a 4x4 sub-block within a macroblock.
    ///
    /// Extracts the relevant neighboring pixels needed for predicting a 4x4 block
    /// at position (x, y) within the larger 16x16 macroblock.
    ///
    /// # Arguments
    ///
    /// * `x` - Horizontal position of the 4x4 block (0-3)
    /// * `y` - Vertical position of the 4x4 block (0-3)
    /// * `block` - The partially reconstructed macroblock
    /// * `top` - Top edge of the macroblock
    /// * `left` - Left edge of the macroblock
    /// * `top_left` - Top-left corner of the macroblock
    /// * `top_right` - Top-right edge pixels
    ///
    /// # Returns
    ///
    /// A tuple containing (top, left, top_left, top_right) edge contexts for the 4x4 block
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
            // Top edge: use macroblock top or previously decoded row
            if y == 0 {
                top.map(|v| v[x * 4..x * 4 + 4].try_into().unwrap())
            } else {
                Some(block[y * 4 - 1][x * 4..x * 4 + 4].try_into().unwrap())
            },
            // Left edge: use macroblock left or previously decoded column
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
            // Top-left corner pixel
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
            // Top-right edge pixels
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

    /// Applies a decoded 4x4 sub-block to the larger 16x16 macroblock.
    ///
    /// # Arguments
    ///
    /// * `x` - Horizontal position of the sub-block (0-3)
    /// * `y` - Vertical position of the sub-block (0-3)
    /// * `sub_block` - The 4x4 decoded sub-block
    /// * `block` - Mutable reference to the 16x16 macroblock being reconstructed
    fn apply_sub_block(x: usize, y: usize, sub_block: [[u8; 4]; 4], block: &mut [[u8; 16]; 16]) {
        for i in 0..4 {
            for j in 0..4 {
                block[y * 4 + i][x * 4 + j] = sub_block[i][j];
            }
        }
    }

    /// Predicts a macroblock using 4x4 block-level prediction (B_PRED mode).
    ///
    /// This mode divides the 16x16 macroblock into sixteen 4x4 blocks and predicts
    /// each independently using its own prediction mode and edge contexts.
    ///
    /// # Arguments
    ///
    /// * `top` - Top edge of the macroblock
    /// * `left` - Left edge of the macroblock
    /// * `top_left` - Top-left corner pixel
    /// * `top_right` - Top-right edge pixels
    ///
    /// # Returns
    ///
    /// A 16x16 array of reconstructed luma values
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
        // Process each 4x4 sub-block
        for (i, row) in self.header.sub_modes.as_ref().unwrap().iter().enumerate() {
            for (j, &mode) in row.iter().enumerate() {
                // Calculate edge contexts for this sub-block
                let (top, left, top_left, top_right) =
                    Self::calc_edges(j, i, &block, top, left, top_left, top_right);
                // Predict the 4x4 block
                let prediction = Self::predict_4x4(mode, &top, &left, &top_left, &top_right);
                // Add residuals
                let sub_block = r.slice::<1>(i * 4 + j) + prediction;
                // Apply to the larger block
                Self::apply_sub_block(j, i, sub_block, &mut block);
            }
        }
        block
    }

    /// Predicts a single 4x4 block using the specified intra-prediction mode.
    ///
    /// # Arguments
    ///
    /// * `mode` - The intra-prediction mode to use
    /// * `top` - Top edge pixels (4 values)
    /// * `left` - Left edge pixels (4 values)
    /// * `top_left` - Top-left corner pixel
    /// * `top_right` - Top-right edge pixels (4 values)
    ///
    /// # Returns
    ///
    /// A 4x4 array of predicted pixel values
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

    /// Predicts the chroma (color) planes of a macroblock.
    ///
    /// Chroma planes use 8x8 blocks (subsampled 2:1 from the 16x16 luma).
    /// Predicts both U and V channels independently using the same mode.
    ///
    /// # Arguments
    ///
    /// * `top` - Top edge chroma values (8 values per channel)
    /// * `left` - Left edge chroma values (8 values per channel)
    /// * `top_left` - Top-left corner chroma values (1 per channel)
    ///
    /// # Returns
    ///
    /// Two 8x8 arrays containing reconstructed U and V chroma planes
    fn predict_chroma(
        &self,
        top: &Option<[[u8; 8]; 2]>,
        left: &Option<[[u8; 8]; 2]>,
        top_left: &Option<[u8; 2]>,
    ) -> [[[u8; 8]; 8]; 2] {
        // Extract U and V components from edge contexts
        let tu = &top.map(|v| v[0]);
        let tv = &top.map(|v| v[1]);
        let lu = &left.map(|v| v[0]);
        let lv = &left.map(|v| v[1]);
        let tlu = &top_left.map(|v| v[0]);
        let tlv = &top_left.map(|v| v[1]);

        // Apply prediction mode to both U and V channels
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

        // Add residuals to predictions
        let ru = MayBeTokens(self.residue.0.as_ref().map(|v| &v.chroma[0]));
        let rv = MayBeTokens(self.residue.0.as_ref().map(|v| &v.chroma[1]));
        let ublock = ru + ublock;
        let vblock = rv + vblock;
        [ublock, vblock]
    }
}
