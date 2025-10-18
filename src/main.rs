#![allow(dead_code)]
mod bit;
mod container;
mod decode;
mod frame;
mod macroblock;
mod tables;
mod types;
mod util;
mod yuv;

use minifb::{Window, WindowOptions};

use crate::{bit::BitReader, container::IVFParser, frame::VP8Frame};

fn main() {
    let data = std::fs::read("samples/vp80-01-intra-1400.ivf").unwrap();
    let mut parser = IVFParser::new(&data).unwrap();

    const WIDTH: usize = 640;
    const HEIGHT: usize = 360;

    let mut window = Window::new("", WIDTH, HEIGHT, WindowOptions::default()).unwrap();
    window.set_target_fps((parser.header.framerate_num / parser.header.framerate_den) as usize);
    let mut buffer = Vec::new();

    while let Some(frame) = parser.next_frame().unwrap() {
        println!("Frame PTS: {}, size: {}", frame.pts, frame.data.len());
        let mut br = BitReader::new(&frame.data);
        let vp8_frame = VP8Frame::parse(&mut br).unwrap();
        let (w, h) = vp8_frame.decode(&mut buffer).unwrap();
        window.update_with_buffer(&buffer, w, h).unwrap();
    }

    while window.is_open() {
        window.update();
    }
}
