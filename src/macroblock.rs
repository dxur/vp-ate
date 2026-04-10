//! VP8 Macroblock Parsing Module
//!
//! This module implements the core macroblock parsing logic for VP8 video decoding.
//! It handles the complete pipeline of reading macroblocks from token data, including:
//!
//! - Intra-prediction mode parsing
//! - Token decoding and dequantization
//! - Inverse DCT/WHT transforms
//! - Residual coefficient parsing
//!
//! # Overview
//!
//! A macroblock in VP8 is a 16x16 pixel region that serves as the basic unit of
//! video compression. Each macroblock contains:
//! - A header describing prediction modes
//! - Residual data (DCT coefficients) representing the difference between
//!   predicted and actual pixel values
//!
//! # Main Entry Points
//!
//! - [`Macroblock::parse`] - Parses all macroblocks in a frame
//! - [`MacroblockHeader::parse`] - Parses a single macroblock header
//! - [`Residuals::parse`] - Parses residual DCT coefficients
//!
//! # Examples
//!
//! ```ignore
//! use vp8_decoder::{Macroblock, VP8FrameHeader, BoolDecoder};
//!
//! let macroblocks = Macroblock::parse(&frame_header, &mut bool_decoder, residual_data)?;
//! for mb in macroblocks {
//!     // Process macroblock prediction and residuals
//! }
//! ```

use strum::FromRepr;

use crate::{
    bit::{BitDecision, BitError, BitReader, BoolDecoder, BoolDecoderState},
    frame::VP8FrameHeader,
    tables::KF_BMODE_PROB,
    util::{vp8_idct4x4, vp8_iwht4x4},
};

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct BlockDebug {
    pub plane: u8,
    pub has_coeff: bool,
    pub raw_coeffs: [i32; 16],

    pub bd1_idx_before: usize,
    pub bd1_range_before: u32,
    pub bd1_value_before: u32,
    pub bd1_byte_offset_before: usize,

    pub bd1_idx_after: usize,
    pub bd1_range_after: u32,
    pub bd1_value_after: u32,
    pub bd1_byte_offset_after: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct MacroblockDebug {
    pub col: u16,
    pub row: u16,

    pub bd0_idx_before: usize,
    pub bd0_range_before: u32,
    pub bd0_value_before: u32,
    pub bd0_byte_offset_before: usize,

    pub mb_skip_coeff: bool,
    pub intra_y_mode: Option<IntraMBMode>,
    pub intra_uv_mode: Option<IntraMBMode>,
    pub sub_modes: Option<[[IntraBMode; 4]; 4]>,

    pub bd1_idx_before: usize,
    pub bd1_range_before: u32,
    pub bd1_value_before: u32,
    pub bd1_byte_offset_before: usize,

    pub blocks: Vec<BlockDebug>,

    pub luma: [[u8; 16]; 16],
    pub chroma: [[[u8; 8]; 8]; 2],
    pub y_pixels: [[u8; 16]; 16],
    pub cb_pixels: [[u8; 8]; 8],
    pub cr_pixels: [[u8; 8]; 8],

    pub bd1_range_after_final: u32,
    pub bd1_value_after_final: u32,
    pub bd1_byte_offset_after_final: usize,
}

// =============================================================================
// Intra Prediction Modes
// =============================================================================

/// Intra-prediction mode for a 16x16 macroblock.
///
/// These modes determine how pixel values are predicted from neighboring
/// already-decoded pixels. VP8 supports 5 prediction modes for luma (Y) blocks:
///
/// # Prediction Modes
///
/// - **DC Prediction**: Predicts all pixels as the average of pixels from the
///   row above and column to the left
/// - **V (Vertical) Prediction**: Copies each column from the row directly above
/// - **H (Horizontal) Prediction**: Copies each row from the column directly to the left
/// - **TM (True Motion) Prediction**: Propagates gradients/second differences to
///   predict diagonal patterns
/// - **B (Block) Prediction**: Uses 4x4 sub-block prediction with 10 different modes
///
/// # Usage
///
/// For chroma (UV) planes, only the first 4 modes (DC, V, H, TM) are used.
/// The BPred mode is only applicable to luma and triggers 4x4 sub-block parsing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromRepr, Serialize)]
#[repr(i8)]
pub enum IntraMBMode {
    /// DC Prediction: average of top and left pixels
    DcPred,
    /// Vertical Prediction: copy from row above
    VPred,
    /// Horizontal Prediction: copy from column to the left
    HPred,
    /// True Motion: propagate second differences
    TmPred,
    /// Block Prediction: each 4x4 Y subblock is independently predicted
    BPred,
}

impl IntraMBMode {
    /// Number of prediction modes available for chroma (UV) planes.
    /// Only DC, V, H, and TM modes apply to chroma.
    pub const NUM_UV_MODES: usize = 4;

    /// Number of prediction modes available for luma (Y) planes.
    /// All 5 modes including BPred apply to luma.
    pub const NUM_YMODES: usize = 5;
}

/// Default probability table for luma (Y) prediction modes in inter frames.
/// Used when no explicit mode probabilities are provided in the frame header.
const DEFAULT_YMODE_PROB: [u8; IntraMBMode::NUM_YMODES - 1] = [112, 86, 140, 37];

/// Default probability table for chroma (UV) prediction modes.
const DEFAULT_UV_MODE_PROB: [u8; IntraMBMode::NUM_UV_MODES - 1] = [162, 101, 204];

/// Probability table for luma (Y) prediction modes in key frames.
/// Key frames use different statistics than inter frames.
const KF_YMODE_PROB: [u8; IntraMBMode::NUM_YMODES - 1] = [145, 156, 163, 128];

/// Binary tree structure for parsing luma modes in inter frames.
///
/// VP8 uses binary decision trees for entropy coding. Each non-leaf node
/// represents a binary decision, with negative values indicating leaf nodes
/// (actual mode values).
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

/// Binary tree structure for parsing luma modes in key frames.
/// Note: BPred is tested first in key frames, unlike inter frames.
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

// =============================================================================
// 4x4 Sub-block Prediction Modes
// =============================================================================

/// Intra-prediction mode for 4x4 sub-blocks within a macroblock.
///
/// When a macroblock uses BPred mode, each of its 16 4x4 luma sub-blocks
/// is predicted independently using one of these 10 directional modes.
///
/// # Directional Modes
///
/// The modes represent different directional predictions:
/// - **DC**: Average of surrounding pixels
/// - **TM**: True motion propagation
/// - **Ve**: Vertical (copies from above)
/// - **He**: Horizontal (copies from left)
/// - **Ld**: Left-down diagonal (↙)
/// - **Rd**: Right-down diagonal (↘)
/// - **Vr**: Vertical-right diagonal (⤡)
/// - **Vl**: Vertical-left diagonal (⤢)
/// - **Hd**: Horizontal-down diagonal (⤵)
/// - **Hu**: Horizontal-up diagonal (⤴)
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd, FromRepr, Serialize)]
#[repr(i8)]
pub enum IntraBMode {
    /// DC Prediction for 4x4 block
    BDcPred,
    /// True Motion for 4x4 block
    BTmPred,
    /// Vertical (Ve) prediction - copy from above
    BVePred,
    /// Horizontal (He) prediction - copy from left
    BHePred,
    /// Left-Down (Ld) diagonal - 45° southwest
    BLdPred,
    /// Right-Down (Rd) diagonal - 45° southeast
    BRdPred,
    /// Vertical-Right (Vr) diagonal
    BVrPred,
    /// Vertical-Left (Vl) diagonal
    BVlPred,
    /// Horizontal-Down (Hd) diagonal
    BHdPred,
    /// Horizontal-Up (Hu) diagonal
    BHuPred,
}

impl IntraBMode {
    /// Total number of 4x4 block prediction modes available.
    pub const NUM_BMODES: usize = 10;
}

/// Converts a 16x16 macroblock mode to an equivalent 4x4 block mode.
///
/// Only DC, V, H, and TM modes can be converted. BPred cannot be converted
/// since it requires explicit 4x4 mode parsing.
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

/// Binary tree structure for parsing 4x4 block modes.
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

/// Probability table for chroma (UV) modes in key frames.
const KF_UV_MODE_PROB: [u8; IntraMBMode::NUM_UV_MODES - 1] = [142, 114, 183];

/// Binary tree structure for parsing chroma (UV) prediction modes.
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

// =============================================================================
// Error Handling
// =============================================================================

/// Errors that can occur during macroblock parsing.
#[derive(Debug)]
pub enum MacroblockError {
    /// The frame data ended unexpectedly during parsing.
    /// This typically indicates corrupted or truncated frame data.
    FrameTooShort,
}

/// Result type alias for macroblock operations.
type Result<T> = std::result::Result<T, MacroblockError>;

/// Converts bit-level errors into macroblock errors.
impl From<BitError> for MacroblockError {
    fn from(_: BitError) -> Self {
        MacroblockError::FrameTooShort
    }
}

// =============================================================================
// Macroblock Header
// =============================================================================

/// Header information for a single macroblock.
///
/// The header contains all prediction mode information needed to reconstruct
/// the macroblock's pixel values. This includes:
///
/// - Whether to skip coefficient decoding (all zeros)
/// - Whether this is an inter or intra macroblock
/// - Prediction modes for luma and chroma planes
/// - 4x4 sub-block modes if using BPred
///
/// # Fields
///
/// - `mb_skip_coeff`: When true, all DCT coefficients are zero (no residual)
/// - `is_inter_mb`: False for intra (key frame), true for inter (predictive)
/// - `mv_mode`: Motion vector mode (only for inter frames)
/// - `intra_y_mode`: Luma (Y) prediction mode
/// - `sub_modes`: 4x4 sub-block modes (only if intra_y_mode == BPred)
/// - `intra_uv_mode`: Chroma (UV) prediction mode
#[derive(Debug, Default, Serialize, Clone)]
pub struct MacroblockHeader {
    /// If true, skip coefficient parsing (all coefficients are zero).
    pub mb_skip_coeff: bool,

    /// Whether this is an inter-frame macroblock (uses motion prediction).
    pub is_inter_mb: bool,

    /// Motion vector mode for inter frames (currently unimplemented).
    pub mv_mode: Option<()>,

    /// Luma (Y) plane prediction mode.
    pub intra_y_mode: Option<IntraMBMode>,

    /// 4x4 sub-block prediction modes (only present when intra_y_mode == BPred).
    /// Contains a 4x4 grid of prediction modes, one for each 4x4 block.
    pub sub_modes: Option<[[IntraBMode; 4]; 4]>,

    /// Chroma (UV) plane prediction mode.
    pub intra_uv_mode: Option<IntraMBMode>,
}

impl MacroblockHeader {
    /// Parses a macroblock header from the bitstream.
    ///
    /// This method reads the prediction mode information for a single macroblock.
    /// It uses context from neighboring macroblocks to improve compression efficiency.
    ///
    /// # Arguments
    ///
    /// * `blocks` - Previously parsed macroblocks (used for context)
    /// * `frame` - Frame header containing global parameters
    /// * `bd` - Boolean decoder for reading entropy-coded bits
    ///
    /// # Context-Adaptive Parsing
    ///
    /// The parser uses neighboring block information to adapt probabilities:
    /// - Top neighbor: block directly above current position
    /// - Left neighbor: block directly to the left
    ///
    /// This context is especially important for 4x4 sub-block mode parsing.
    ///
    /// # Returns
    ///
    /// A parsed `MacroblockHeader` or an error if parsing fails.
    fn parse<'a, 'b>(
        blocks: &Vec<Macroblock>,
        frame: &VP8FrameHeader,
        bd: &mut BoolDecoder<'a, 'b>,
    ) -> Result<Self> {
        let mut mb = MacroblockHeader::default();

        let index = blocks.len();
        let mb_width = frame.mb_width as usize;

        // Determine indices of neighboring macroblocks for context
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

        // Parse segmentation information (not yet implemented)
        if let Some(true) = frame.update_mb_segmentation_map {
            unimplemented!("Segmentation is not yet implemented");
        }

        // Parse skip coefficient flag
        mb.mb_skip_coeff = if let Some(p) = frame.prob_skip_false {
            bd.read_bool(p)? != 0
        } else {
            false
        };

        // Determine if this is an inter or intra macroblock
        mb.is_inter_mb = if !frame.is_key {
            unimplemented!("Inter frames not implemented");
        } else {
            false
        };

        if mb.is_inter_mb {
            unimplemented!()
        } else {
            // Parse intra macroblock prediction modes

            // Read luma (Y) prediction mode using key frame tree
            let intra_y_mode = bd
                .read_treed(&KF_YMODE_TREE, &KF_YMODE_PROB)
                .map(IntraMBMode::from_repr)?
                .unwrap();

            // If BPred mode, parse individual 4x4 sub-block modes
            let sub_modes =
                if intra_y_mode == IntraMBMode::BPred {
                    let mut sub_modes = [[IntraBMode::BDcPred; 4]; 4];

                    // Parse each 4x4 block using neighboring block context
                    for y in 0..4 {
                        for x in 0..4 {
                            // Get mode from block above for context
                            let above = if y > 0 {
                                // Use previously parsed block in same macroblock
                                sub_modes[y - 1][x]
                            } else {
                                // Use bottom row of macroblock above
                                top.map(|t| {
                                    let h = &blocks[t].header;
                                    h.sub_modes.as_ref().map(|m| m[3][x]).unwrap_or_else(|| {
                                        h.intra_y_mode.unwrap().try_into().unwrap()
                                    })
                                })
                                .unwrap_or(IntraBMode::BDcPred)
                            };

                            // Get mode from block to the left for context
                            let left_ctx = if x > 0 {
                                // Use previously parsed block in same macroblock
                                sub_modes[y][x - 1]
                            } else {
                                // Use rightmost column of macroblock to the left
                                left.map(|l| {
                                    let h = &blocks[l].header;
                                    h.sub_modes.as_ref().map(|m| m[y][3]).unwrap_or_else(|| {
                                        h.intra_y_mode.unwrap().try_into().unwrap()
                                    })
                                })
                                .unwrap_or(IntraBMode::BDcPred)
                            };

                            // Use context-specific probability table
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

            // Parse chroma (UV) prediction mode
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

// =============================================================================
// DCT Token Parsing
// =============================================================================

/// Probability tables for DCT coefficient categories.
/// Each category represents a range of coefficient values.
const PCAT1: [u8; 1] = [159];
const PCAT2: [u8; 2] = [165, 145];
const PCAT3: [u8; 3] = [173, 148, 140];
const PCAT4: [u8; 4] = [176, 155, 140, 135];
const PCAT5: [u8; 5] = [180, 157, 141, 134, 130];
const PCAT6: [u8; 11] = [254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129];

/// Maps DCT coefficient positions to frequency bands.
///
/// VP8 groups coefficients into 8 bands based on their frequency:
/// - Band 0: DC coefficient (lowest frequency)
/// - Bands 1-7: Progressively higher frequencies
///
/// This grouping allows different probability distributions for
/// different frequency ranges, improving compression.
const COEFF_BANDS: [usize; 16] = [0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7];

/// Base values for each DCT coefficient category.
/// The actual coefficient value is: base + extra_bits
const CATEGORY_BASE: [i32; 6] = [5, 7, 11, 19, 35, 67];

/// Represents a DCT coefficient token type.
///
/// VP8 uses tokens to efficiently encode the distribution of DCT coefficients.
/// Most coefficients are small (0-4) or zero, so special tokens represent these.
/// Larger values are encoded as categories with extra bits.
///
/// # Token Types
///
/// - `Dct0` to `Dct4`: Small literal values (0-4)
/// - `DctCat1` to `DctCat6`: Categories for larger values
///   - Cat1: 5-6 (2 values)
///   - Cat2: 7-10 (4 values)
///   - Cat3: 11-18 (8 values)
///   - Cat4: 19-34 (16 values)
///   - Cat5: 35-66 (32 values)
///   - Cat6: 67-2048 (1982 values)
/// - `DctEob`: End of block marker (all remaining coefficients are zero)
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
    /// Total number of token types.
    pub const NUM_DCT_TOKENS: usize = 12;

    /// Returns the probability table for reading extra bits in category tokens.
    ///
    /// For category tokens (Cat1-Cat6), additional bits are needed to determine
    /// the exact coefficient value within that category's range.
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

/// Binary tree for parsing DCT tokens (with EOB).
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

/// Binary tree for parsing DCT tokens (without EOB - used after first non-zero).
/// Once a non-zero coefficient is found, we know the block isn't empty,
/// so EOB is less likely and we can use a different tree.
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

/// Zigzag scan order for DCT coefficients.
///
/// DCT coefficients are stored in raster order but parsed in zigzag order.
/// This groups low-frequency coefficients together, improving compression
/// since most energy is in low frequencies.
///
/// The pattern starts at DC (0,0) and zigzags through increasing frequencies:
/// ```text
///  0  1  5  6
///  2  4  7 12
///  3  8 11 13
///  9 10 14 15
/// ```
const ZIGZAG: [u8; 16] = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];

// =============================================================================
// Color Plane Types
// =============================================================================

/// Identifies different coefficient planes in a macroblock.
///
/// VP8 uses YUV color space with separate planes for luma and chroma:
/// - Y (luma): 16x16 pixels, divided into 16 4x4 blocks
/// - U/V (chroma): 8x8 pixels each, divided into 4 4x4 blocks each
///
/// # Plane Types
///
/// - `Y2`: DC coefficients from all 16 luma blocks (after WHT)
/// - `Y(bool)`: Luma AC coefficients (bool indicates if DC is in Y2)
/// - `U`: U chroma coefficients
/// - `V`: V chroma coefficients
#[derive(PartialEq, Eq, Clone, Copy)]
pub enum Plane {
    /// Y2 plane: WHT-transformed DC coefficients from all luma blocks
    Y2,
    /// Y plane: Luma AC (and DC if bool is false) coefficients
    Y(bool),
    /// U chroma plane
    U,
    /// V chroma plane
    V,
}

impl Plane {
    /// Returns the first coefficient index to parse for this plane.
    ///
    /// For Y blocks with DC in Y2, skip the DC coefficient (start at index 1).
    /// For all other planes, start at index 0 (the DC coefficient).
    pub fn first_coeff(&self) -> usize {
        match self {
            Plane::Y(true) => 1, // Skip DC if it's in Y2
            _ => 0,
        }
    }

    /// Returns the probability table index for this plane type.
    ///
    /// VP8 uses different probability distributions for different planes:
    /// - Index 0: Y with DC in Y2 (AC only)
    /// - Index 1: Y2 plane
    /// - Index 2: UV chroma
    /// - Index 3: Y with DC included
    pub fn index(&self) -> usize {
        match self {
            Plane::Y(true) => 0,  // Y AC only
            Plane::Y2 => 1,       // Y2 DC
            Plane::U => 2,        // UV chroma
            Plane::V => 2,        // UV chroma
            Plane::Y(false) => 3, // Y with DC
        }
    }
}

// =============================================================================
// Token Storage
// =============================================================================

/// Optional array of tokens with compile-time size.
///
/// This wrapper allows slicing and type conversion of token arrays while
/// maintaining compile-time size information.
#[derive(Debug, Clone)]
pub struct MayBeTokens<'a, const N: usize>(pub Option<&'a [Tokens; N]>);

impl<'a, const N: usize> MayBeTokens<'a, N> {
    /// Creates a sub-slice with a different size.
    ///
    /// # Arguments
    ///
    /// * `offset` - Starting index in the original slice
    ///
    /// # Type Parameters
    ///
    /// * `M` - Size of the resulting slice
    pub fn slice<const M: usize>(&self, offset: usize) -> MayBeTokens<'a, M> {
        if let Some(slice) = self.0 {
            let subslice = &slice[offset..offset + M];
            MayBeTokens(Some(subslice.try_into().unwrap()))
        } else {
            MayBeTokens(None)
        }
    }
}

/// A 4x4 block of DCT coefficients.
///
/// Stores 16 dequantized DCT coefficients in natural (raster) order.
/// These coefficients represent the frequency-domain representation of
/// a 4x4 pixel block.
///
/// # Coefficient Ordering
///
/// Coefficients are stored in raster order:
/// ```text
///  0  1  2  3
///  4  5  6  7
///  8  9 10 11
/// 12 13 14 15
/// ```
///
/// But are parsed in zigzag order (see [`ZIGZAG`]).
#[derive(Debug, Clone, Default)]
pub struct Tokens(pub [i32; 16]);

impl Tokens {
    /// Parses DCT coefficients from the bitstream.
    ///
    /// This method:
    /// 1. Reads entropy-coded tokens in zigzag order
    /// 2. Decodes tokens to coefficient values
    /// 3. Applies dequantization (multiplies by DC/AC quantizers)
    /// 4. Returns coefficients in raster order
    ///
    /// # Arguments
    ///
    /// * `plane` - Which color plane is being parsed (affects probabilities)
    /// * `coeff_probs` - Frame-level probability tables for coefficient parsing
    /// * `dcq` - DC quantizer value for dequantization
    /// * `acq` - AC quantizer value for dequantization
    /// * `complexity` - Context from neighboring blocks (0-2):
    ///   - 0: Both neighbors have no coefficients
    ///   - 1: One neighbor has coefficients
    ///   - 2: Both neighbors have coefficients
    /// * `bd` - Boolean decoder for reading entropy-coded bits
    ///
    /// # Returns
    ///
    /// A tuple containing:
    /// - The parsed and dequantized coefficient block
    /// - Boolean indicating if any non-zero coefficients were found
    ///
    /// # Coefficient Parsing Algorithm
    ///
    /// The parser maintains several pieces of state:
    /// - `skip`: After encountering a zero token, assume more zeros follow
    /// - `complexity`: Updated after each coefficient to improve prediction
    ///
    /// For each coefficient position (in zigzag order):
    /// 1. Select probability table based on band, plane, and complexity
    /// 2. Parse token from bitstream
    /// 3. If EOB token, all remaining coefficients are zero
    /// 4. Convert token to absolute value (possibly reading extra bits)
    /// 5. Read sign bit
    /// 6. Apply dequantization: value * (DC/AC quantizer)
    /// 7. Store in raster-order position using zigzag mapping
    pub fn parse<'a, 'b>(
        plane: Plane,
        coeff_probs: &[[[[u8; 11]; 3]; 8]; 4],
        dcq: i16,
        acq: i16,
        mut complexity: usize,
        bd: &mut BoolDecoder<'a, 'b>,
    ) -> Result<(Self, bool, BoolDecoderState, usize)> {
        macro_rules! rb {
            ($p:expr) => {{ bd.read_bool($p)? }};
        }

        macro_rules! read_treed_rec {
            ($tree:expr, $probs:expr) => {{
                let tree = &$tree;
                let probs = $probs;
                let mut i = 0i8;
                loop {
                    let bit = rb!(probs[(i >> 1) as usize]);
                    i = tree[(i as usize) + bit as usize];
                    if i <= 0 {
                        break -i;
                    }
                }
            }};
        }

        let mut block = [0i32; 16];
        let mut has_coeff = false;
        let mut skip = false;

        // Parse coefficients in zigzag order
        for i in plane.first_coeff()..16 {
            let band = COEFF_BANDS[i];
            let probs = &coeff_probs[plane.index()][band][complexity];

            // Use different tree based on whether we've seen a non-zero yet
            let token_repr = if skip {
                read_treed_rec!(COEFF_TREE_NOEOB, &probs[1..])
            } else {
                read_treed_rec!(COEFF_TREE, probs)
            };

            let token = Token::from_repr(token_repr).unwrap();

            // EOB means all remaining coefficients are zero
            if let Token::DctEob = token {
                break;
            }

            // Decode token to absolute coefficient value
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
                    // Read extra bits to determine exact value in category
                    let probs = token.pcat().unwrap();
                    let extra = {
                        let mut v = 0u32;
                        for &p in probs {
                            v = (v << 1) | rb!(p) as u32;
                        }
                        v
                    };
                    CATEGORY_BASE[token as usize - Token::DctCat1 as usize] + extra as i32
                }
                _ => unreachable!(),
            };

            has_coeff = true;
            skip = false;

            // Update complexity based on coefficient magnitude
            complexity = match abs_value {
                0 => 0,
                1 => 1,
                _ => 2,
            };

            // Read sign bit
            let sign = bd.read_bool(128)?;
            if sign != 0 {
                abs_value = -abs_value;
            }

            // Apply dequantization and store in raster order
            let zigzag = ZIGZAG[i];
            block[zigzag as usize] = abs_value * if zigzag == 0 { dcq as i32 } else { acq as i32 };
        }

        let state_after = bd.get_state();
        let idx_after = bd.count();
        Ok((Self(block), has_coeff, state_after, idx_after))
    }

    /// Reads extra bits for DCT coefficient categories.
    ///
    /// Category tokens represent ranges of values. Extra bits determine
    /// the exact value within that range. For example, Cat1 (range 5-6)
    /// needs 1 extra bit to distinguish between 5 and 6.
    ///
    /// # Arguments
    ///
    /// * `probs` - Probability table for each extra bit
    /// * `bd` - Boolean decoder
    ///
    /// # Returns
    ///
    /// The extra value to add to the category base
    fn dct_extra<'a, 'b>(probs: &[u8], bd: &mut BoolDecoder<'a, 'b>) -> Result<u32> {
        let mut v = 0u32;
        for &p in probs {
            v = (v << 1) | (bd.read_bool(p)? as u32);
        }
        Ok(v)
    }
}

// =============================================================================
// Residual Data
// =============================================================================

/// Complete residual data for a macroblock.
///
/// After prediction, VP8 stores the difference (residual) between predicted
/// and actual pixel values as DCT coefficients. A macroblock's residuals include:
///
/// - **Luma (Y)**: 16 4x4 blocks of DCT coefficients
/// - **Chroma (U/V)**: 4 4x4 blocks each for U and V
///
/// For macroblocks with Y2 mode (non-BPred intra blocks), the DC coefficients
/// from all 16 luma blocks are collected, WHT-transformed, and stored separately
/// as the Y2 plane. This improves compression by exploiting correlation between
/// DC values.
///
/// # Structure
///
/// ```text
/// Macroblock (16x16 pixels)
/// ├── Luma (Y): 16 blocks (4x4 grid)
/// │   ├── Block 0-3   (top row)
/// │   ├── Block 4-7
/// │   ├── Block 8-11
/// │   └── Block 12-15 (bottom row)
/// ├── Chroma U: 4 blocks (2x2 grid)
/// └── Chroma V: 4 blocks (2x2 grid)
/// ```
/// Complete residual data for a macroblock.
#[derive(Debug, Clone)]
pub struct Residuals {
    pub luma: [Tokens; 16],
    pub chroma: [[Tokens; 4]; 2],
}

impl Residuals {
    /// Parses all residual coefficients for a macroblock.
    ///
    /// This is the main workhorse method that:
    /// 1. Optionally parses Y2 DC coefficients (if applicable)
    /// 2. Parses all 16 luma blocks
    /// 3. Parses U and V chroma blocks
    /// 4. Applies inverse transforms (IDCT/IWHT)
    /// 5. Updates neighbor context for subsequent blocks
    ///
    /// # Arguments
    ///
    /// * `(_, mb_col, block)` - Tuple containing:
    ///   - Row index (unused but kept for future use)
    ///   - Column index (for context lookups)
    ///   - Macroblock header (for prediction mode information)
    /// * `frame` - Frame header with quantizer and probability data
    /// * `has_coeff_vec` - Context vector tracking which neighbors have coefficients:
    ///   - Index 0: Left neighbor state
    ///   - Index 1+: Top neighbor states (one per column)
    ///   Each entry is (Y2_has_coeff, Y_has_coeff[4], UV_has_coeff[2][2])
    /// * `bd` - Boolean decoder for reading coefficient tokens
    ///
    /// # Y2 Processing
    ///
    /// For non-BPred intra blocks and certain inter blocks, the DC coefficients
    /// from all 16 luma blocks are:
    /// 1. Collected into a 4x4 block
    /// 2. Inverse Walsh-Hadamard transformed (IWHT)
    /// 3. Distributed back to their respective luma blocks
    ///
    /// This is the Y2 plane optimization.
    ///
    /// # Context Tracking
    ///
    /// The `has_coeff_vec` is critical for compression efficiency. It tracks
    /// which neighboring blocks have non-zero coefficients, allowing the
    /// entropy decoder to adapt probabilities. The context includes:
    /// - Previous block in same row (left context)
    /// - Blocks in row above (top context)
    ///
    /// # Returns
    ///
    /// A `Residuals` struct containing all parsed and inverse-transformed coefficients.
    fn parse<'a, 'b>(
        (_, mb_col, block): (u16, u16, &MacroblockHeader),
        frame: &VP8FrameHeader,
        has_coeff_vec: &mut Vec<(bool, [bool; 4], [[bool; 2]; 2])>,
        bd: &mut BoolDecoder<'a, 'b>,
    ) -> Result<(Self, Vec<BlockDebug>)> {
        let mut debug_blocks = Vec::new();
        let mbx = mb_col as usize + 1; // Index in has_coeff_vec (offset by 1 for left)

        let mut y2_has_coeff = false;
        let mut luma_dc = None;

        // Parse Y2 plane if applicable
        // Y2 is used for non-BPred intra blocks and certain inter blocks
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
            // Calculate complexity from neighboring Y2 blocks
            let mut complexity = 0;
            if has_coeff_vec[mbx].0 {
                complexity += 1; // Top neighbor has Y2 coefficients
            }
            if has_coeff_vec[0].0 {
                complexity += 1; // Left neighbor has Y2 coefficients
            }

            // Parse Y2 block (4x4 of DC values from luma blocks)
            let state_before = bd.count();
            let state_before_full = bd.get_state();
            let (mut residual, has_coeff, state_after, idx_after) = Tokens::parse(
                Plane::Y2,
                &frame.coeff_probs,
                frame.y2dc,
                frame.y2ac,
                complexity,
                bd,
            )?;

            debug_blocks.push(BlockDebug {
                plane: 1, // Y2
                has_coeff,
                raw_coeffs: residual.0,
                bd1_idx_before: state_before,
                bd1_range_before: state_before_full.range,
                bd1_value_before: state_before_full.value,
                bd1_byte_offset_before: state_before_full.byte_offset,
                bd1_idx_after: idx_after,
                bd1_range_after: state_after.range,
                bd1_value_after: state_after.value,
                bd1_byte_offset_after: state_after.byte_offset,
            });

            // Inverse Walsh-Hadamard Transform on Y2 block
            vp8_iwht4x4(&mut residual.0);
            luma_dc = Some(residual);
            y2_has_coeff = true; // Typically pinned to true

            // Update context for next macroblock
            has_coeff_vec[mbx].0 = has_coeff;
            has_coeff_vec[0].0 = has_coeff;
        }

        // Parse 16 luma (Y) blocks in 4x4 grid
        let mut luma: [Tokens; 16] = std::array::from_fn(|_| Default::default());
        for i in 0..4 {
            // Row index in 4x4 grid
            let mut left = has_coeff_vec[0].1[i];
            for j in 0..4 {
                // Column index in 4x4 grid
                // Calculate complexity from neighbors
                let mut complexity = 0;
                if has_coeff_vec[mbx].1[j] {
                    complexity += 1; // Top neighbor
                }
                if left {
                    complexity += 1; // Left neighbor
                }

                // Parse luma block
                let state_before = bd.count();
                let state_before_full = bd.get_state();
                let (mut residual, has_coeff, state_after, idx_after) = Tokens::parse(
                    Plane::Y(y2_has_coeff),
                    &frame.coeff_probs,
                    frame.ydc,
                    frame.yac,
                    complexity,
                    bd,
                )?;

                debug_blocks.push(BlockDebug {
                    plane: if y2_has_coeff { 0 } else { 3 },
                    has_coeff,
                    raw_coeffs: residual.0,
                    bd1_idx_before: state_before,
                    bd1_range_before: state_before_full.range,
                    bd1_value_before: state_before_full.value,
                    bd1_byte_offset_before: state_before_full.byte_offset,
                    bd1_idx_after: idx_after,
                    bd1_range_after: state_after.range,
                    bd1_value_after: state_after.value,
                    bd1_byte_offset_after: state_after.byte_offset,
                });

                // If Y2 exists, replace DC coefficient with Y2 value
                if let Some(ref luma_dc) = luma_dc {
                    residual.0[0] = luma_dc.0[i * 4 + j];
                }

                // Inverse DCT transform
                vp8_idct4x4(&mut residual.0);
                luma[i * 4 + j] = residual;

                // Update context
                has_coeff_vec[mbx].1[j] = has_coeff;
                left = has_coeff;
            }
            has_coeff_vec[0].1[i] = left;
        }

        // Parse chroma (U and V) blocks
        let mut chroma: [[Tokens; 4]; 2] = std::array::from_fn(|_| Default::default());
        for (p, plane) in [Plane::U, Plane::V].into_iter().enumerate() {
            for i in 0..2 {
                // Row index in 2x2 grid
                let mut left = has_coeff_vec[0].2[p][i];
                for j in 0..2 {
                    // Column index in 2x2 grid
                    // Calculate complexity from neighbors
                    let mut complexity = 0;
                    if has_coeff_vec[mbx].2[p][j] {
                        complexity += 1;
                    }
                    if left {
                        complexity += 1;
                    }

                    // Parse chroma block
                    let state_before = bd.count();
                    let state_before_full = bd.get_state();
                    let (mut residual, has_coeff, state_after, idx_after) = Tokens::parse(
                        plane,
                        &frame.coeff_probs,
                        frame.uvdc,
                        frame.uvac,
                        complexity,
                        bd,
                    )?;

                    debug_blocks.push(BlockDebug {
                        plane: 2, // UV
                        has_coeff,
                        raw_coeffs: residual.0,
                        bd1_idx_before: state_before,
                        bd1_range_before: state_before_full.range,
                        bd1_value_before: state_before_full.value,
                        bd1_byte_offset_before: state_before_full.byte_offset,
                        bd1_idx_after: idx_after,
                        bd1_range_after: state_after.range,
                        bd1_value_after: state_after.value,
                        bd1_byte_offset_after: state_after.byte_offset,
                    });

                    // Inverse DCT transform
                    vp8_idct4x4(&mut residual.0);
                    chroma[p][i * 2 + j] = residual;

                    // Update context
                    has_coeff_vec[mbx].2[p][j] = has_coeff;
                    left = has_coeff;
                }
                has_coeff_vec[0].2[p][i] = left;
            }
        }

        Ok((Self { luma, chroma }, debug_blocks))
    }
}

// =============================================================================
// Macroblock Container Types
// =============================================================================

/// Optional residual data for a macroblock.
///
/// When `mb_skip_coeff` is true, no residual data is present (all coefficients
/// are zero). This wrapper makes that distinction explicit.
#[derive(Debug)]
pub struct Residue(pub Option<Residuals>);

/// A complete macroblock with header and residual data.
///
/// This represents all information needed to decode a 16x16 pixel macroblock:
/// - Position in the frame
/// - Prediction modes (from header)
/// - Residual DCT coefficients (if not skipped)
///
/// # Decoding Pipeline
///
/// To reconstruct pixels from a macroblock:
/// 1. Generate prediction based on header modes
/// 2. Add residuals to prediction
/// 3. Clip values to valid range [0, 255]
#[derive(Debug)]
pub struct Macroblock {
    /// Macroblock position (column, row) in the frame.
    pub pos: (u16, u16),

    /// Header containing prediction mode information.
    pub header: MacroblockHeader,

    /// Residual DCT coefficients (None if mb_skip_coeff is true).
    pub residue: Residue,
}

impl Macroblock {
    /// Parses all macroblocks in a frame.
    ///
    /// This is the main entry point for macroblock parsing. It iterates through
    /// all macroblock positions in raster order, parsing headers and residuals.
    ///
    /// # Arguments
    ///
    /// * `frame` - Frame header containing dimensions and global parameters
    /// * `bd` - Boolean decoder for reading macroblock headers
    /// * `residual_data` - Raw bitstream data for DCT coefficients
    ///
    /// # Partitioning
    ///
    /// VP8 frames contain two types of data:
    /// 1. **Macroblock headers**: Prediction modes, parsed with `bd`
    /// 2. **Residual coefficients**: DCT data, parsed from `residual_data`
    ///
    /// This separation allows parallel processing of residuals.
    ///
    /// Currently only single-partition mode is implemented. Multi-partition
    /// mode splits residual data across multiple bitstreams for parallel decoding.
    ///
    /// # Context Management
    ///
    /// The parser maintains `has_coeff_vec` which tracks coefficient presence
    /// in neighboring blocks. This is used for context-adaptive entropy coding:
    /// - Index 0: Left neighbor of current macroblock
    /// - Index 1+: Top neighbors (one per macroblock column)
    ///
    /// The context is reset at the start of each row and after skip blocks.
    ///
    /// # Error Handling
    ///
    /// Parsing errors include a panic with position information for debugging.
    /// This helps identify which macroblock caused issues in corrupted streams.
    ///
    /// # Returns
    ///
    /// A vector of all parsed macroblocks in raster order, or an error if
    /// parsing fails.
    pub fn parse<'a, 'b>(
        frame: &VP8FrameHeader,
        bd: &mut BoolDecoder<'a, 'b>,
        residual_data: &'b [u8],
    ) -> Result<(Vec<Self>, Vec<MacroblockDebug>, Vec<BitDecision>)> {
        // Multi-partition mode not yet implemented
        if frame.num_partitions > 1 {
            unimplemented!();
        }

        let mut blocks = Vec::new();
        let mut debugs = Vec::new();

        // Context vector: [left, top_0, top_1, ..., top_N]
        // Each entry: (Y2_has_coeff, Y_has_coeff[4], UV_has_coeff[2][2])
        let mut has_coeff_vec =
            vec![(false, [false; 4], [[false; 2]; 2]); frame.mb_width as usize + 1];

        // Initialize residual decoder
        let mut residual_br = BitReader::new(residual_data);
        let mut residual_bd = BoolDecoder::new(&mut residual_br)?;

        // Parse macroblocks in raster order
        for i in 0..frame.mb_height {
            for j in 0..frame.mb_width {
                // Parse macroblock header
                let bd0_idx_before = bd.count();
                let state_before_header = bd.get_state();
                let header = MacroblockHeader::parse(&mut blocks, frame, bd)?;

                // Parse residuals (if not skipped)
                let bd1_idx_before = residual_bd.count();
                let state_before_residue = residual_bd.get_state();
                let (residue, debug_blocks) = if !header.mb_skip_coeff {
                    let (r, db) = Residuals::parse(
                        (i, j, &header),
                        frame,
                        &mut has_coeff_vec,
                        &mut residual_bd,
                    )
                    .inspect_err(|e| panic!("i: {i}, j: {j}, e: {e:?}"))?;
                    (Residue(Some(r)), db)
                } else {
                    // Skip coefficient: reset context appropriately
                    if let Some(IntraMBMode::BPred) = header.intra_y_mode {
                        // BPred: only reset Y and UV context
                        has_coeff_vec[0].1 = Default::default();
                        has_coeff_vec[0].2 = Default::default();
                        has_coeff_vec[j as usize + 1].1 = Default::default();
                        has_coeff_vec[j as usize + 1].2 = Default::default();
                    } else {
                        // Non-BPred: reset all context including Y2
                        has_coeff_vec[0] = Default::default();
                        has_coeff_vec[j as usize + 1] = Default::default();
                    }
                    (Residue(None), Vec::new())
                };

                let state_after_residue = residual_bd.get_state();

                debugs.push(MacroblockDebug {
                    col: j,
                    row: i,
                    bd0_idx_before,
                    bd0_range_before: state_before_header.range,
                    bd0_value_before: state_before_header.value,
                    bd0_byte_offset_before: state_before_header.byte_offset,
                    mb_skip_coeff: header.mb_skip_coeff,
                    intra_y_mode: header.intra_y_mode,
                    intra_uv_mode: header.intra_uv_mode,
                    sub_modes: header.sub_modes,
                    bd1_idx_before,
                    bd1_range_before: state_before_residue.range,
                    bd1_value_before: state_before_residue.value,
                    bd1_byte_offset_before: state_before_residue.byte_offset,
                    blocks: debug_blocks,
                    luma: [[0; 16]; 16], // To be filled during decode
                    chroma: [[[0; 8]; 8]; 2],
                    y_pixels: [[0; 16]; 16],
                    cb_pixels: [[0; 8]; 8],
                    cr_pixels: [[0; 8]; 8],
                    bd1_range_after_final: state_after_residue.range,
                    bd1_value_after_final: state_after_residue.value,
                    bd1_byte_offset_after_final: state_after_residue.byte_offset,
                });

                blocks.push(Macroblock {
                    pos: (j, i),
                    header,
                    residue,
                });
            }
            // Reset left context at start of each row
            has_coeff_vec[0] = Default::default();
        }
        Ok((blocks, debugs, residual_bd.log))
    }
}
