"""
test_residue_decoder_golden.py

Isolated test for ResidueDecoder.
- TokenDecoder is stubbed: we feed raw_coeffs/has_coeff directly from golden
- IDCT is stubbed: identity transform (coeffs pass straight through)
- We verify luma[16][16] and chroma[2][8][8] against golden
- We verify hc_left_out/hc_top_out against golden
"""

import json
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import test

_HERE        = os.path.dirname(os.path.abspath(__file__))
_ROOT        = os.path.dirname(_HERE)
_GOLDEN_PATH = os.path.join(_ROOT, "golden.json")

INTRA_Y_MODE = {
    "DcPred": 0,
    "VPred":  1,
    "HPred":  2,
    "TmPred": 3,
    "BPred":  4,
}


# ---------------------------------------------------------------------------
# Load golden
# ---------------------------------------------------------------------------
def _load_golden():
    with open(_GOLDEN_PATH) as f:
        return json.load(f)


def _build_coeff_probs_flat(cp):
    data = bytearray(1056)
    for pl in range(4):
        for band in range(8):
            for ctx in range(3):
                for tok in range(11):
                    idx = ((pl * 8 + band) * 3 + ctx) * 11 + tok
                    data[idx] = cp[pl][band][ctx][tok]
    return int.from_bytes(data, 'big')


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _r(sig):
    try:    return int(sig.value)
    except: return None


def _unpack_luma(flat_val):
    raw = int(flat_val)
    return [
        [_s16((raw >> ((r * 16 + c) * 16)) & 0xFFFF) for c in range(16)]
        for r in range(16)
    ]


def _unpack_chroma(flat_val):
    raw = int(flat_val)
    return [
        [
            [_s16((raw >> ((p * 64 + r * 8 + c) * 16)) & 0xFFFF) for c in range(8)]
            for r in range(8)
        ]
        for p in range(2)
    ]


def _s16(v):
    return v - 0x10000 if v >= 0x8000 else v


# ---------------------------------------------------------------------------
# Reset
# ---------------------------------------------------------------------------
async def _reset(dut, cycles=4):
    dut.rst.value              = 0
    dut.mb_valid.value         = 0
    dut.mb_intra_y_mode.value  = 0
    dut.mb_skip_coeff.value    = 0
    dut.hc_left.value          = 0
    dut.hc_top.value           = 0
    dut.ydc.value              = 0
    dut.yac.value              = 0
    dut.y2dc.value             = 0
    dut.y2ac.value             = 0
    dut.uvdc.value             = 0
    dut.uvac.value             = 0
    dut.coeff_probs_flat.value = 0
    dut.res_ready.value        = 0
    dut.td_busy.value          = 0
    dut.td_coeffs_flat.value   = 0
    dut.td_has_coeff.value     = 0
    dut.td_coeff_valid.value   = 0
    dut.idct_coeff_ready.value = 1
    dut.idct_block_valid.value = 0
    dut.idct_block_flat.value  = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 1
    await RisingEdge(dut.clk)


# ---------------------------------------------------------------------------
# Identity IDCT stub
# Whenever idct_coeff_valid asserts, echo coefficients back as idct_block
# one cycle later.
# ---------------------------------------------------------------------------
async def _idct_stub(dut):
    dut.idct_coeff_ready.value = 1
    dut.idct_block_valid.value = 0
    dut.idct_block_flat.value  = 0
    while True:
        await RisingEdge(dut.clk)
        if _r(dut.idct_coeff_valid) and _r(dut.idct_coeff_ready):
            coeff_flat = int(dut.idct_coeff_flat.value)
            await RisingEdge(dut.clk)
            dut.idct_block_flat.value  = coeff_flat
            dut.idct_block_valid.value = 1
            await RisingEdge(dut.clk)
            dut.idct_block_valid.value = 0
            dut.idct_block_flat.value  = 0


# ---------------------------------------------------------------------------
# Token decoder stub
# Waits for td_start, then drives one block worth of coeffs/has_coeff
# from the pending_blocks list.
# ---------------------------------------------------------------------------
async def _td_stub(dut, pending_blocks):
    """
    pending_blocks: list used as a queue (pop from front).
    Each entry: (coeffs[16], has_coeff).
    """
    dut.td_busy.value        = 0
    dut.td_coeff_valid.value = 0
    dut.td_has_coeff.value   = 0
    dut.td_coeffs_flat.value = 0

    while True:
        await RisingEdge(dut.clk)

        if not _r(dut.td_start):
            continue

        # td_start pulsed — consume next block
        if not pending_blocks:
            cocotb.log.error("td_stub: td_start but no pending blocks!")
            continue

        coeffs, has_coeff = pending_blocks.pop(0)

        # Assert busy immediately
        dut.td_busy.value = 1

        # Pack coeffs into flat 256-bit word
        flat = 0
        for i, c in enumerate(coeffs):
            flat |= (int(c) & 0xFFFF) << (i * 16)

        # Simulate a few cycles processing
        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)

        # Drive result
        dut.td_coeffs_flat.value = flat
        dut.td_has_coeff.value   = 1 if has_coeff else 0
        dut.td_coeff_valid.value = 1
        dut.td_busy.value        = 0
        await RisingEdge(dut.clk)
        dut.td_coeff_valid.value = 0
        dut.td_coeffs_flat.value = 0
        dut.td_has_coeff.value   = 0


# ---------------------------------------------------------------------------
# Build expected luma from golden blocks (identity IDCT)
#
# Identity IDCT means: output[r][c] = coeff[r*4 + c] exactly.
# ResidueDecoder places each 4x4 block at luma[brow*4+r][bcol*4+c].
# If has_y2: luma[brow*4][bcol*4] is overwritten with y2_dc[brow][bcol]
#   which is coeff_tree_noeob output from Y2 block passed through identity IWHT
#   i.e. y2_coeffs in zigzag position mapped to 4x4 raster.
#   Y2 raw_coeffs[brow*4+bcol] → y2_dc[brow][bcol].
# ---------------------------------------------------------------------------
def _expected_luma(blocks, has_y2):
    luma = [[0] * 16 for _ in range(16)]

    y2_coeffs = None
    y_blocks  = []

    for blk in blocks:
        if blk["plane"] == 1:
            c = list(blk["raw_coeffs"]) + [0] * (16 - len(blk["raw_coeffs"]))
            y2_coeffs = c
        elif blk["plane"] in (0, 3):
            c = list(blk["raw_coeffs"]) + [0] * (16 - len(blk["raw_coeffs"]))
            y_blocks.append(c)

    for bi, coeffs in enumerate(y_blocks):
        brow = bi // 4
        bcol = bi % 4
        for r in range(4):
            for c in range(4):
                luma[brow * 4 + r][bcol * 4 + c] = coeffs[r * 4 + c]

    if has_y2 and y2_coeffs is not None:
        for brow in range(4):
            for bcol in range(4):
                luma[brow * 4][bcol * 4] = y2_coeffs[brow * 4 + bcol]

    return luma


def _expected_chroma(blocks):
    chroma = [[[0] * 8 for _ in range(8)] for _ in range(2)]
    u_blocks = []
    v_blocks = []

    for blk in blocks:
        if blk["plane"] == 2:
            c = list(blk["raw_coeffs"]) + [0] * (16 - len(blk["raw_coeffs"]))
            if len(u_blocks) < 4:
                u_blocks.append(c)
            else:
                v_blocks.append(c)

    for plane_idx, plane_blocks in enumerate([u_blocks, v_blocks]):
        for t, coeffs in enumerate(plane_blocks):
            urow = t >> 1
            ucol = t & 1
            for r in range(4):
                for c in range(4):
                    chroma[plane_idx][urow * 4 + r][ucol * 4 + c] = coeffs[r * 4 + c]

    return chroma


# ---------------------------------------------------------------------------
# Build expected hc_left_out and hc_top_out from golden blocks
# Encoding: [8]=y2, [7:4]=y_col, [3:2]=u_row, [1:0]=v_row
#   hc_top_out:  last row of each column  (brow=3 for Y, urow=1 for UV)
#   hc_left_out: last col of each row     (bcol=3 for Y, ucol=1 for UV)
# ---------------------------------------------------------------------------
def _expected_hc(blocks, has_y2):
    y2_hc = False
    y_hc  = [False] * 16
    u_hc  = [False] * 4
    v_hc  = [False] * 4

    y_idx = u_idx = v_idx = 0

    for blk in blocks:
        p  = blk["plane"]
        hc = bool(blk["has_coeff"])
        if p == 1:
            y2_hc = hc
        elif p in (0, 3):
            if y_idx < 16:
                y_hc[y_idx] = hc
                y_idx += 1
        elif p == 2:
            if u_idx < 4:
                u_hc[u_idx] = hc
                u_idx += 1
            elif v_idx < 4:
                v_hc[v_idx] = hc
                v_idx += 1

    def bit(b):
        return 1 if b else 0

    # hc_top_out: bottom row of MB (brow=3 → bi 12,13,14,15)
    hc_top = (
        (bit(y2_hc) if has_y2 else 0) << 8 |
        bit(y_hc[15]) << 7 |   # brow=3,bcol=3
        bit(y_hc[14]) << 6 |   # brow=3,bcol=2
        bit(y_hc[13]) << 5 |   # brow=3,bcol=1
        bit(y_hc[12]) << 4 |   # brow=3,bcol=0
        bit(u_hc[3])  << 3 |   # urow=1,ucol=1 → but top uses urow
        bit(u_hc[2])  << 2 |   # urow=1,ucol=0
        bit(v_hc[3])  << 1 |   # vrow=1,vcol=1
        bit(v_hc[2])  << 0     # vrow=1,vcol=0
    )

    # hc_left_out: rightmost col of MB (bcol=3 → bi 3,7,11,15)
    hc_left = (
        (bit(y2_hc) if has_y2 else 0) << 8 |
        bit(y_hc[15]) << 7 |   # brow=3,bcol=3
        bit(y_hc[11]) << 6 |   # brow=2,bcol=3
        bit(y_hc[7])  << 5 |   # brow=1,bcol=3
        bit(y_hc[3])  << 4 |   # brow=0,bcol=3
        bit(u_hc[3])  << 3 |   # urow=1,ucol=1
        bit(u_hc[1])  << 2 |   # urow=0,ucol=1
        bit(v_hc[3])  << 1 |   # vrow=1,vcol=1
        bit(v_hc[1])  << 0     # vrow=0,vcol=1
    )

    return hc_top, hc_left

@test.module("ResidueDecoderTest")
@cocotb.test()
async def test_residue_decoder_golden(dut):
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())

    g      = _load_golden()
    gframe = g["frame"]
    gmbs   = g["macroblocks"]

    cp_flat  = _build_coeff_probs_flat(gframe["coeff_probs"])
    mb_width = (gframe["width"] + 15) // 16

    await _reset(dut)

    # Start stubs
    pending_blocks = []
    cocotb.start_soon(_idct_stub(dut))
    cocotb.start_soon(_td_stub(dut, pending_blocks))

    # Frame context (constant)
    dut.ydc.value              = gframe["ydc"]  & 0xFFFF
    dut.yac.value              = gframe["yac"]  & 0xFFFF
    dut.y2dc.value             = gframe["y2dc"] & 0xFFFF
    dut.y2ac.value             = gframe["y2ac"] & 0xFFFF
    dut.uvdc.value             = gframe["uvdc"] & 0xFFFF
    dut.uvac.value             = gframe["uvac"] & 0xFFFF
    dut.coeff_probs_flat.value = cp_flat

    failures   = []
    total      = 0
    hc_top_vec = [0] * mb_width
    hc_left_vec = [0] * (mb_width + 1)

    for gm in gmbs:
        col    = gm["col"]
        row    = gm["row"]
        blocks = gm.get("blocks", [])

        has_y2       = (gm["intra_y_mode"] != "BPred")
        hc_top_in    = hc_top_vec[col]
        hc_left_in   = hc_left_vec[col]
        
        # Load all blocks for this MB into the pending queue
        for blk in blocks:
            coeffs = list(blk["raw_coeffs"]) + [0] * (16 - len(blk["raw_coeffs"]))
            pending_blocks.append((coeffs, blk["has_coeff"]))

        # Compute expected outputs
        exp_luma             = _expected_luma(blocks, has_y2)
        exp_chroma           = _expected_chroma(blocks)
        exp_hc_top, exp_hc_left = _expected_hc(blocks, has_y2)

        # Present MB to DUT
        dut.mb_intra_y_mode.value = INTRA_Y_MODE[gm["intra_y_mode"]]
        dut.mb_skip_coeff.value   = 1 if gm["mb_skip_coeff"] else 0
        dut.hc_left.value         = hc_left_in
        dut.hc_top.value          = hc_top_in
        dut.mb_valid.value        = 1

        # Wait for mb_ready
        timeout = 50
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if _r(dut.mb_ready): break
        else:
            failures.append(f"MB({col},{row}): mb_ready timeout")
            break

        await RisingEdge(dut.clk)
        dut.mb_valid.value = 0

        # Wait for res_valid
        timeout = 10000
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if _r(dut.res_valid): break
        else:
            failures.append(f"MB({col},{row}): res_valid timeout")
            break

        # Latch outputs
        got_luma    = _unpack_luma(dut.luma_flat.value)
        got_chroma  = _unpack_chroma(dut.chroma_flat.value)
        got_hc_top  = _r(dut.hc_top_out)
        got_hc_left = _r(dut.hc_left_out)

        dut.res_ready.value = 1
        await RisingEdge(dut.clk)
        dut.res_ready.value = 0

        total += 1
        mb_ok = True

        # --- PRINT DATA COMPARISONS ---
        cocotb.log.info(f"MB({col},{row}) Comparison Details:")
        
        # Flatten and Print Luma
        flat_got_luma = [val for row in got_luma for val in row]
        flat_exp_luma = [val for row in exp_luma for val in row]
        cocotb.log.debug(f"  LUMA GOT: {flat_got_luma}")
        cocotb.log.debug(f"  LUMA REF: {flat_exp_luma}")
        if flat_got_luma != flat_exp_luma:
            mb_ok = False
            cocotb.log.error(f"  !! Luma Mismatch detected")

        # Flatten and Print Chroma
        for p in range(2):
            p_name = "U" if p == 0 else "V"
            flat_got_chroma = [val for row in got_chroma[p] for val in row]
            flat_exp_chroma = [val for row in exp_chroma[p] for val in row]
            cocotb.log.debug(f"  CHROMA {p_name} GOT: {flat_got_chroma}")
            cocotb.log.debug(f"  CHROMA {p_name} REF: {flat_exp_chroma}")
            if flat_got_chroma != flat_exp_chroma:
                mb_ok = False
                cocotb.log.error(f"  !! Chroma {p_name} Mismatch detected")

        # Context Printing
        cocotb.log.info(f"  HC_TOP  GOT: 0x{got_hc_top:x} REF: 0x{exp_hc_top:x}")
        cocotb.log.info(f"  HC_LEFT GOT: 0x{got_hc_left:x} REF: 0x{exp_hc_left:x}")
        if got_hc_top != exp_hc_top or got_hc_left != exp_hc_left:
            mb_ok = False
            cocotb.log.error(f"  !! Context Mismatch detected")

        if mb_ok:
            cocotb.log.info(f"MB({col},{row}) PASSED")
        else:
            failures.append(f"MB({col},{row}) data mismatch")
            break

        # Propagate context
        hc_top_vec[col]      = got_hc_top
        hc_left_vec[col + 1] = got_hc_left

    if not failures:
        cocotb.log.info(f"ALL {total} MBs PASSED")
    else:
        raise AssertionError(failures[0])