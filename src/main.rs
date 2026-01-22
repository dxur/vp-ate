//! VP8 video decoder demonstration application.
//!
//! This application reads an IVF file containing VP8-encoded video,
//! decodes each frame, and displays them in a window using minifb.
//!
//! # Controls
//!
//! - **F**: Pause/unpause playback
//! - **N**: Next frame (when paused)

#![allow(dead_code)]
mod bit;
mod container;
mod decode;
mod frame;
mod macroblock;
mod prediction;
mod tables;
mod util;

use std::cell::Cell;

use minifb::{Key, KeyRepeat, Window, WindowOptions};

use crate::bit::BitReader;
use crate::container::IVFParser;
use crate::frame::VP8Frame;

thread_local! {
    static FRAME_COUNTER: Cell<usize> = Cell::new(0);
}

/// Entry point for the VP8 decoder application.
///
/// Reads `args[1]`, decodes VP8 frames, and displays them in a window.
/// Supports basic playback controls for pausing and frame-by-frame navigation.
fn main() {
    let data = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let mut parser = IVFParser::new(&data).unwrap();

    const WIDTH: usize = 1280;
    const HEIGHT: usize = 720;

    let mut window = Window::new(
        "",
        WIDTH,
        HEIGHT,
        WindowOptions {
            resize: false,
            ..Default::default()
        },
    )
    .unwrap();
    window.set_target_fps((parser.header.framerate_num / parser.header.framerate_den) as usize);

    let mut buffer = Vec::new();
    let mut frames = Vec::new();

    while let Some(frame) = parser.next_frame().unwrap() {
        println!("Frame PTS: {}, size: {}", frame.pts, frame.data.len());
        frames.push(frame);
    }

    let paused = Cell::new(false);
    let mut frame_iter = frames.iter();

    loop {
        let mut update = |window: &mut Window| {
            if let Some(frame) = frame_iter.next() {
                println!("FrameNumber: {}", FRAME_COUNTER.get());
                // write_to_wepb("output.webp", frame.data).unwrap();
                let mut br = BitReader::new(&frame.data);
                let vp8_frame = VP8Frame::parse(&mut br).unwrap();
                let (w, h) = vp8_frame.decode(&mut buffer);
                window.update_with_buffer(&buffer, w, h).unwrap();
                FRAME_COUNTER.set(FRAME_COUNTER.get() + 1);
            } else {
                frame_iter = frames.iter();
                FRAME_COUNTER.set(0);
            }
        };

        if paused.get() {
            window.update();
        } else {
            update(&mut window);
        }

        if window.is_key_pressed(Key::F, KeyRepeat::Yes) {
            paused.update(|v| !v);
        }

        if paused.get() {
            if window.is_key_pressed(Key::N, KeyRepeat::Yes) {
                update(&mut window);
            }
        }

        if !window.is_open() || window.is_key_pressed(Key::Q, KeyRepeat::Yes) {
            return;
        }
    }
}
