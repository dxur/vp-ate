#![allow(dead_code)]
mod bit;
mod container;
mod decode;
mod frame;
mod macroblock;
mod prediction;
mod tables;
mod util;

use bit::BitReader;
use container::IVFParser;
use frame::VP8Frame;
use serde::Serialize;

#[derive(Serialize)]
struct FullDebugRecord {
    frame_data: Vec<u8>,
    frame: FrameInfo,
    macroblocks: Vec<macroblock::MacroblockDebug>,
    bd0: Vec<bit::BitDecision>,
    bd1: Vec<bit::BitDecision>,
}

#[derive(Serialize)]
struct FrameInfo {
    width: u16,
    height: u16,
    part1_off: usize,
    bd0_idx: usize,
    ydc: i16,
    yac: i16,
    y2dc: i16,
    y2ac: i16,
    uvdc: i16,
    uvac: i16,
    coeff_probs: [[[[u8; 11]; 3]; 8]; 4],
    prob_skip_false: Option<u8>,
    mb_no_skip_coeff: bool,
}

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("Usage: vp8-debug <file.ivf>");
    let data = std::fs::read(&path).expect("cannot read file");
    let mut parser = IVFParser::new(&data).unwrap();

    // Find the first key frame.
    let frame_data = loop {
        let frame = parser.next_frame().unwrap().expect("no frames in file");
        if frame.data[0] & 1 == 0 {
            break frame.data.to_vec();
        }
    };

    let mut br = BitReader::new(&frame_data);

    // After parsing the frame header, bit reader will be at the start of partition 1 (residuals)
    // Actually, VP8Frame::parse stores partition0_len.
    let mut vp8 = VP8Frame::parse(&mut br).expect("failed to decode frame");

    // Reconstruct pixels and fill debug_data
    let mut pixels = Vec::new();
    vp8.decode(&mut pixels);

    // Partition 1 starts after partition 0 header (partition0_len + 10 bytes).
    let part1_start = vp8.header.partition0_len + 10;

    let full_record = FullDebugRecord {
        frame_data,
        frame: FrameInfo {
            width: vp8.header.width,
            height: vp8.header.height,
            part1_off: part1_start,
            bd0_idx: 0,
            ydc: vp8.header.ydc,
            yac: vp8.header.yac,
            y2dc: vp8.header.y2dc,
            y2ac: vp8.header.y2ac,
            uvdc: vp8.header.uvdc,
            uvac: vp8.header.uvac,
            coeff_probs: vp8.header.coeff_probs,
            prob_skip_false: vp8.header.prob_skip_false,
            mb_no_skip_coeff: vp8.header.mb_no_skip_coeff,
        },
        macroblocks: vp8.debug_data,
        bd0: vp8.bd0_log,
        bd1: vp8.bd1_log,
    };

    println!("{}", serde_json::to_string(&full_record).unwrap());
}
