import math
import os
import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import test

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
_HERE    = os.path.dirname(os.path.abspath(__file__))
IVF_PATH = os.environ.get("VP_ATE_IVF", os.path.join(_HERE, "input.ivf"))
PPM_PATH = os.path.join(_HERE, "output.ppm")
TIMEOUT  = 5_000_000   # clock cycles before giving up


# ---------------------------------------------------------------------------
# IVF parsing — pure Python, mirrors the Rust implementation in ivf_reader.rs
# ---------------------------------------------------------------------------
def _parse_ivf_first_frame(path: str):
    """
    Read the first VP8 frame from an IVF file.

    Returns (width, height, frame_bytes) where frame_bytes is the raw
    codec payload with the IVF container stripped.
    """
    with open(path, "rb") as f:
        hdr = f.read(32)

    if len(hdr) < 32:
        raise ValueError("IVF file too short to contain a header")
    if hdr[:4] != b"DKIF":
        raise ValueError(f"Not an IVF file (magic={hdr[:4]!r})")
    version     = struct.unpack_from("<H", hdr, 4)[0]
    header_size = struct.unpack_from("<H", hdr, 6)[0]
    if version != 0:
        raise ValueError(f"Unsupported IVF version {version}")
    if header_size != 32:
        raise ValueError(f"Unexpected IVF header size {header_size}")

    width  = struct.unpack_from("<H", hdr, 12)[0]
    height = struct.unpack_from("<H", hdr, 14)[0]

    with open(path, "rb") as f:
        f.seek(32)                          # skip file header
        frame_hdr = f.read(12)             # 4-byte size + 8-byte PTS
        if len(frame_hdr) < 12:
            raise ValueError("IVF file contains no frames")
        frame_size = struct.unpack_from("<I", frame_hdr, 0)[0]
        frame_data = f.read(frame_size)

    if len(frame_data) < frame_size:
        raise ValueError("IVF frame data truncated")

    return width, height, bytes(frame_data)


def _vp8_part1_offset(frame_data: bytes) -> int:
    """
    Decode the first-partition size from the VP8 uncompressed frame header
    (bytes 1..3, little-endian 19-bit field) and return the byte offset
    where partition 1 begins.

    VP8 spec §9.3:
        frame_tag       = data[0] | data[1]<<8 | data[2]<<16
        key_frame       = !(frame_tag & 1)
        version         = (frame_tag >> 1) & 7
        show_frame      = (frame_tag >> 4) & 1
        first_part_size = frame_tag >> 5          # upper 19 bits

    The 10-byte uncompressed data chunk precedes the first partition, so:
        part1_off = 10 + first_part_size
    """
    if len(frame_data) < 4:
        raise ValueError("VP8 frame too short to parse header")
    tag = frame_data[0] | (frame_data[1] << 8) | (frame_data[2] << 16)
    first_part_size = tag >> 5
    return 10 + first_part_size


# ---------------------------------------------------------------------------
# Signal helpers
# ---------------------------------------------------------------------------
def _r(sig):
    try:    return int(sig.value)
    except: return None


def _read_y_pixels(dut):
    raw = _r(dut.snap_y_pixels_flat)
    if raw is None:
        return None
    return [[(raw >> ((r * 16 + c) * 8)) & 0xFF
             for c in range(16)] for r in range(16)]


def _read_cb_pixels(dut):
    raw = _r(dut.snap_cb_pixels_flat)
    if raw is None:
        return None
    return [[(raw >> ((r * 8 + c) * 8)) & 0xFF
             for c in range(8)] for r in range(8)]


def _read_cr_pixels(dut):
    raw = _r(dut.snap_cr_pixels_flat)
    if raw is None:
        return None
    return [[(raw >> ((r * 8 + c) * 8)) & 0xFF
             for c in range(8)] for r in range(8)]


# ---------------------------------------------------------------------------
# DUT reset
# ---------------------------------------------------------------------------
async def _reset(dut, cycles=5):
    dut.rst.value      = 0
    dut.p0_data.value  = 0
    dut.p0_valid.value = 0
    dut.p1_data.value  = 0
    dut.p1_valid.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 1
    await RisingEdge(dut.clk)


# ---------------------------------------------------------------------------
# Byte streamer — feeds one partition into the FIFO port
# ---------------------------------------------------------------------------
async def _stream(dut, data_sig, valid_sig, ready_sig, data: bytes, label: str):
    for i, b in enumerate(data):
        data_sig.value  = b
        valid_sig.value = 1
        for _ in range(10_000):
            await RisingEdge(dut.clk)
            if int(ready_sig.value):
                break
        else:
            raise TimeoutError(
                f"{label}: ready never asserted at byte {i}/{len(data)}"
            )
    valid_sig.value = 0
    cocotb.log.info(f"{label}: streamed {len(data)} bytes")


# ---------------------------------------------------------------------------
# PPM writer — YCbCr 4:2:0 → RGB (BT.601 full-range, VP8 §14.1)
# ---------------------------------------------------------------------------
def _write_ppm(pixel_buf: dict, width: int, height: int, path: str):
    mb_cols = math.ceil(width  / 16)
    mb_rows = math.ceil(height / 16)

    img_r = bytearray(width * height)
    img_g = bytearray(width * height)
    img_b = bytearray(width * height)

    def clamp(v):
        return max(0, min(255, int(v)))

    for mb_row in range(mb_rows):
        for mb_col in range(mb_cols):
            mb = pixel_buf.get((mb_col, mb_row))
            if mb is None:
                continue
            y_pl  = mb["y"]
            cb_pl = mb["cb"]
            cr_pl = mb["cr"]

            for py in range(16):
                for px in range(16):
                    fx = mb_col * 16 + px
                    fy = mb_row * 16 + py
                    if fx >= width or fy >= height:
                        continue
                    Y  = y_pl[py][px]
                    Cb = cb_pl[py >> 1][px >> 1]
                    Cr = cr_pl[py >> 1][px >> 1]
                    R  = Y                           + 1.402    * (Cr - 128)
                    G  = Y - 0.344136 * (Cb - 128)  - 0.714136 * (Cr - 128)
                    B  = Y + 1.772    * (Cb - 128)
                    idx = fy * width + fx
                    img_r[idx] = clamp(R)
                    img_g[idx] = clamp(G)
                    img_b[idx] = clamp(B)

    with open(path, "wb") as f:
        f.write(f"P6\n{width} {height}\n255\n".encode())
        for i in range(width * height):
            f.write(struct.pack("BBB", img_r[i], img_g[i], img_b[i]))

    cocotb.log.info(
        f"PPM written → {path}  "
        f"({width}×{height}, {len(pixel_buf)} MBs captured)"
    )


# ---------------------------------------------------------------------------
# Demo test — no assertions, just drive and capture
# ---------------------------------------------------------------------------
@test.module("VpAteTest")
@cocotb.test()
async def demo_drive_and_capture(dut):
    """
    Streams the first frame of an IVF file into VpAteTest and writes the
    decoded output as output.ppm.  No correctness checks are performed.
    """
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())

    # ── Load IVF ────────────────────────────────────────────────────────────
    if not os.path.exists(IVF_PATH):
        raise FileNotFoundError(
            f"IVF file not found: {IVF_PATH}\n"
            f"Set the VP_ATE_IVF environment variable to override the path."
        )

    width, height, frame_data = _parse_ivf_first_frame(IVF_PATH)
    part1_off = _vp8_part1_offset(frame_data)

    p0_bytes = frame_data[:part1_off]
    p1_bytes = frame_data[part1_off:]

    cocotb.log.info(
        f"IVF: {width}×{height}  "
        f"frame={len(frame_data)}B  part1_off={part1_off}  "
        f"p0={len(p0_bytes)}B  p1={len(p1_bytes)}B"
    )

    # ── Reset ────────────────────────────────────────────────────────────────
    await _reset(dut)

    # ── Stream both partitions concurrently ──────────────────────────────────
    pixel_buf: dict = {}

    p0_task = cocotb.start_soon(
        _stream(dut, dut.p0_data, dut.p0_valid, dut.p0_ready, p0_bytes, "P0")
    )
    p1_task = cocotb.start_soon(
        _stream(dut, dut.p1_data, dut.p1_valid, dut.p1_ready, p1_bytes, "P1")
    )

    # ── Main loop: collect pixels inline on res_valid_out, stop on frame_done
    #
    # Pixel collection MUST happen synchronously in this loop — not in a
    # separate coroutine — so that snap ports are read on the exact same
    # rising edge that res_valid_out is asserted, before any task switch can
    # occur.  A background coroutine races against cancellation and can miss
    # the last macroblock (or every macroblock if frame_done and res_valid_out
    # coincide), leaving pixel_buf empty and producing no PPM.
    # ────────────────────────────────────────────────────────────────────────
    frame_done = False
    for cycle in range(TIMEOUT):
        await RisingEdge(dut.clk)

        # Collect pixels immediately when res_valid_out is asserted
        if _r(dut.res_valid_out):
            col   = _r(dut.snap_mb_col)
            row   = _r(dut.snap_mb_row)
            ypix  = _read_y_pixels(dut)
            cbpix = _read_cb_pixels(dut)
            crpix = _read_cr_pixels(dut)
            if col is not None and ypix and cbpix and crpix:
                pixel_buf[(col, row)] = {"y": ypix, "cb": cbpix, "cr": crpix}
                cocotb.log.debug(f"  MB({col},{row}) captured at cycle {cycle}")

        if _r(dut.frame_done):
            cocotb.log.info(f"frame_done at cycle {cycle}")
            frame_done = True
            break

    if not frame_done:
        cocotb.log.warning(f"Timed out after {TIMEOUT} cycles — writing partial PPM")

    # ── Tear down streamer tasks ─────────────────────────────────────────────
    for t in (p0_task, p1_task):
        t.cancel()
        try:
            await t
        except Exception:
            pass

    # ── Write PPM ────────────────────────────────────────────────────────────
    _write_ppm(pixel_buf, width, height, PPM_PATH)