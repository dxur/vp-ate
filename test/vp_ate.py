"""
test_golden.py — Bit-by-bit VP8 pipeline integrity test driven by golden.json.

Data source: golden["frame_data"] — raw VP8 frame bytes (IVF container
already stripped). Split at golden["frame"]["part1_off"] into p0/p1.

Three parallel monitors run throughout the simulation:

  bd0_monitor  — checks every (prob, bit) produced by bd0 against
                 golden["bd0"] in order. Stops on first mismatch.

  bd1_monitor  — same for golden["bd1"].

  mb_monitor   — on every res_valid pulse verifies the MB header,
                 per-block has_coeff + raw_coeffs, IDCT residuals,
                 and final pixels against golden["macroblocks"].

All three monitors write into a shared `failures` list. The main
coroutine waits for frame_done (or timeout) then reports.

DUT: VpAteTest (two-FIFO version) with the snap ports added per
VpAteTest_snap_ports.sv. Additionally requires these ports wired
in VpAteTest:

  output var logic        bd0_bit_valid,   // decoder.bd0.valid & decoder.bd0.ready
  output var logic [7:0]  bd0_bit_prob,    // decoder.bd0.prob  (on accepted read)
  output var logic        bd0_bit_value,   // decoder.bd0.data

  output var logic        bd1_bit_valid,
  output var logic [7:0]  bd1_bit_prob,
  output var logic        bd1_bit_value,

  output var logic        res_valid_out,   // decoder.res_valid

  assign bd0_bit_valid = decoder.bd0.valid & decoder.bd0.ready;
  assign bd0_bit_prob  = decoder.bd0.prob;
  assign bd0_bit_value = decoder.bd0.data;
  assign bd1_bit_valid = decoder.bd1.valid & decoder.bd1.ready;
  assign bd1_bit_prob  = decoder.bd1.prob;
  assign bd1_bit_value = decoder.bd1.data;
  assign res_valid_out = decoder.res_valid;
"""

import json
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import test

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
_HERE        = os.path.dirname(os.path.abspath(__file__))
_ROOT        = os.path.dirname(_HERE)
_GOLDEN_PATH = os.path.join(_ROOT, ".", "golden.json")

# ---------------------------------------------------------------------------
# Mode string → int
# ---------------------------------------------------------------------------
_YMODE  = {"DcPred": 0, "VPred": 1, "HPred": 2, "TmPred": 3, "BPred": 4}
_UVMODE = {"DcPred": 0, "VPred": 1, "HPred": 2, "TmPred": 3}
_BMODE  = {
    "BDcPred": 0, "BTmPred": 1, "BVePred": 2, "BHePred": 3,
    "BLdPred": 4, "BRdPred": 5, "BVrPred": 6, "BVlPred": 7,
    "BHdPred": 8, "BHuPred": 9,
}
def _read_luma(dut):
    raw = _r(dut.snap_luma_flat)
    if raw is None: return None
    return [[[(raw >> ((p*64+r*8+c)*16)) & 0xFFFF for c in range(8)] for r in range(8)] for p in range(2)]

def _read_chroma(dut):
    raw = _r(dut.snap_chroma_flat)
    if raw is None: return None
    return [[(raw >> ((r*16+c)*16)) & 0xFFFF for c in range(16)] for r in range(16)]


def _ymode(v):  return _YMODE[v]  if isinstance(v, str) else int(v)
def _uvmode(v): return _UVMODE[v] if isinstance(v, str) else int(v)
def _bmode(v):  return _BMODE[v]  if isinstance(v, str) else int(v)

# ---------------------------------------------------------------------------
# Signal read helpers
# ---------------------------------------------------------------------------
def _r(sig):
    try:    return int(sig.value)
    except: return None

def _s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v

def _read_luma(dut):
    raw = _r(dut.snap_luma_flat)
    if raw is None: return None
    return [[_s16((raw >> ((r*16+c)*16)) & 0xFFFF)
             for c in range(16)] for r in range(16)]

def _read_chroma(dut):
    raw = _r(dut.snap_chroma_flat)
    if raw is None: return None
    return [[[_s16((raw >> ((p*64+r*8+c)*16)) & 0xFFFF)
              for c in range(8)] for r in range(8)] for p in range(2)]

def _read_y_pixels(dut):
    raw = _r(dut.snap_y_pixels_flat)
    if raw is None: return None
    return [[(raw >> ((r*16+c)*8)) & 0xFF
             for c in range(16)] for r in range(16)]

def _read_cb_pixels(dut):
    raw = _r(dut.snap_cb_pixels_flat)
    if raw is None: return None
    return [[(raw >> ((r*8+c)*8)) & 0xFF for c in range(8)] for r in range(8)]

def _read_cr_pixels(dut):
    raw = _r(dut.snap_cr_pixels_flat)
    if raw is None: return None
    return [[(raw >> ((r*8+c)*8)) & 0xFF for c in range(8)] for r in range(8)]

def _read_sub_modes(dut):
    raw = _r(dut.snap_sub_modes_flat)
    if raw is None: return [[0]*4 for _ in range(4)]
    return [[(raw >> ((y*4+x)*4)) & 0xF
             for x in range(4)] for y in range(4)]

def _read_block_coeffs(dut):
    raw = _r(dut.snap_block_coeffs_flat)
    if raw is None: return [0]*16
    return [_s16((raw >> (i*16)) & 0xFFFF) for i in range(16)]

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
# Stream partition bytes into a FIFO port
# ---------------------------------------------------------------------------
async def _stream(dut, data_sig, valid_sig, ready_sig, data, label):
    for i, b in enumerate(data):
        data_sig.value  = b
        valid_sig.value = 1
        for _ in range(10_000):
            await RisingEdge(dut.clk)
            if int(ready_sig.value):
                break
        else:
            raise TimeoutError(
                f"{label} ready never asserted at byte {i}/{len(data)}"
            )
    valid_sig.value = 0
    cocotb.log.info(f"{label}: streamed {len(data)} bytes.")

# ---------------------------------------------------------------------------
# BD bit monitor
# Fires on every cycle where the handshake completed (valid_sig=1 means
# bd.valid & bd.ready were both high that cycle).
# ---------------------------------------------------------------------------
async def _bd_monitor(dut, valid_sig, prob_sig, bit_sig,
                      ref_bits: list, label: str, failures: list):
    idx        = 0
    n_reported = 0
    MAX_REPORT = 10

    while True:
        await RisingEdge(dut.clk)
        if not int(valid_sig.value):
            continue

        dut_prob = int(prob_sig.value)
        dut_bit  = int(bit_sig.value)

        # DUT read more bits than reference
        if idx >= len(ref_bits):
            if n_reported < MAX_REPORT:
                msg = (
                    f"{label} OVER-READ at bit index {idx} "
                    f"(reference has {len(ref_bits)} bits total).\n"
                    f"  DUT: prob={dut_prob} bit={dut_bit}"
                )
                failures.append({
                    "label": f"{label}_OVERREAD",
                    "idx": idx, "msg": msg
                })
                cocotb.log.error(msg)
                n_reported += 1
            idx += 1
            continue

        ref      = ref_bits[idx]
        ref_prob = ref["prob"]
        ref_bit  = int(ref["bit"])

        if dut_prob != ref_prob or dut_bit != ref_bit:
            if n_reported < MAX_REPORT:
                msg = (
                    f"{label} MISMATCH at bit index {idx} "
                    f"({idx + 1}th bool read on this partition):\n"
                    f"  DUT  prob={dut_prob:3d}  bit={dut_bit}\n"
                    f"  REF  prob={ref_prob:3d}  bit={ref_bit}\n"
                    f"  First {idx} bits matched correctly."
                )
                failures.append({
                    "label": f"{label}_MISMATCH",
                    "idx": idx, "msg": msg,
                    "dut_prob": dut_prob, "dut_bit": dut_bit,
                    "ref_prob": ref_prob, "ref_bit": ref_bit,
                })
                cocotb.log.error(msg)
                n_reported += 1

        idx += 1

# ---------------------------------------------------------------------------
# Block monitor — captures per-block data on snap_block_valid
# ---------------------------------------------------------------------------
async def _block_monitor(dut, block_log: list):
    while True:
        await RisingEdge(dut.clk)
        if _r(dut.snap_block_valid):
            block_log.append({
                "seq":       _r(dut.snap_block_seq),
                "has_coeff": bool(_r(dut.snap_block_has_coeff)),
                "coeffs":    _read_block_coeffs(dut),
            })

# ---------------------------------------------------------------------------
# MB monitor — fires on res_valid, checks all levels
# ---------------------------------------------------------------------------
async def _mb_monitor(dut, ref_mbs: list, block_log: list,
                      p0_total: int, p1_total: int, failures: list):
    mb_count = 0

    for gm in ref_mbs:
        ref_col  = gm["col"]
        ref_row  = gm["row"]

        # ── Wait for res_valid ──────────────────────────────────────────────
        for _ in range(5_000_000):
            await RisingEdge(dut.clk)
            if _r(dut.res_valid_out):
                break
        else:
            p0c = p0_total - (_r(dut.p0_fill_low) or 0)
            p1c = p1_total - (_r(dut.p1_fill_low) or 0)
            msg = (
                f"TIMEOUT waiting for res_valid at "
                f"ref MB({ref_col},{ref_row}) after {mb_count} MBs.\n"
                f"  p0 consumed={p0c}/{p0_total}  "
                f"p1 consumed={p1c}/{p1_total}"
            )
            failures.append({"label": "MB_TIMEOUT", "msg": msg})
            cocotb.log.error(msg)
            return

        # ── Snapshot ────────────────────────────────────────────────────────
        dut_col      = _r(dut.snap_mb_col)
        dut_row      = _r(dut.snap_mb_row)
        dut_ymode    = _r(dut.snap_intra_y_mode)
        dut_uvmode   = _r(dut.snap_intra_uv_mode)
        dut_skip     = bool(_r(dut.snap_skip_coeff))
        dut_submodes = _read_sub_modes(dut)
        dut_luma     = _read_luma(dut)
        dut_chroma   = _read_chroma(dut)
        dut_ypix     = _read_y_pixels(dut)
        dut_cbpix    = _read_cb_pixels(dut)
        dut_crpix    = _read_cr_pixels(dut)
        p0_consumed  = p0_total - (_r(dut.p0_fill_low) or 0)
        p1_consumed  = p1_total - (_r(dut.p1_fill_low) or 0)

        mb_blocks = list(block_log)
        block_log.clear()
        mb_count += 1

        ref_ymode  = _ymode(gm["intra_y_mode"])
        ref_uvmode = _uvmode(gm["intra_uv_mode"])
        ref_skip   = bool(gm["mb_skip_coeff"])

        # ── Level 1: position ───────────────────────────────────────────────
        if dut_col != ref_col or dut_row != ref_row:
            msg = (
                f"[L1] MB position: DUT=({dut_col},{dut_row})  "
                f"REF=({ref_col},{ref_row})"
            )
            failures.append({"label": "L1_POS", "msg": msg})
            cocotb.log.error(msg)
            return   # all subsequent MBs will be wrong too

        # ── Level 1: header fields ──────────────────────────────────────────
        bd0_delta = p0_consumed - gm["bd0_byte_offset_before"]

        if dut_ymode != ref_ymode:
            msg = (
                f"[L1] MB({ref_col},{ref_row}) ymode: "
                f"DUT={dut_ymode} REF={ref_ymode}\n"
                f"     p0_consumed={p0_consumed}  "
                f"bd0_before={gm['bd0_byte_offset_before']}  "
                f"delta={bd0_delta}"
            )
            failures.append({"label": "L1_YMODE", "mb": (ref_col, ref_row), "msg": msg})
            cocotb.log.error(msg)
        elif dut_uvmode != ref_uvmode:
            msg = (
                f"[L1] MB({ref_col},{ref_row}) uvmode: "
                f"DUT={dut_uvmode} REF={ref_uvmode}\n"
                f"     p0_consumed={p0_consumed}  "
                f"bd0_before={gm['bd0_byte_offset_before']}  "
                f"delta={bd0_delta}"
            )
            failures.append({"label": "L1_UVMODE", "mb": (ref_col, ref_row), "msg": msg})
            cocotb.log.error(msg)
        elif dut_skip != ref_skip:
            msg = (
                f"[L1] MB({ref_col},{ref_row}) skip_coeff: "
                f"DUT={dut_skip} REF={ref_skip}"
            )
            failures.append({"label": "L1_SKIP", "mb": (ref_col, ref_row), "msg": msg})
            cocotb.log.error(msg)
        elif gm["intra_y_mode"] == "BPred" and gm["sub_modes"]:
            ref_sm = gm["sub_modes"]
            for sy in range(4):
                for sx in range(4):
                    rv = _bmode(ref_sm[sy][sx]) \
                         if isinstance(ref_sm[sy][sx], str) \
                         else int(ref_sm[sy][sx])
                    if dut_submodes[sy][sx] != rv:
                        msg = (
                            f"[L1] MB({ref_col},{ref_row}) "
                            f"sub_modes[{sy}][{sx}]: "
                            f"DUT={dut_submodes[sy][sx]} REF={rv}\n"
                            f"     p0_consumed={p0_consumed}  "
                            f"bd0_before={gm['bd0_byte_offset_before']}  "
                            f"delta={bd0_delta}"
                        )
                        failures.append({
                            "label": "L1_SUBMODE",
                            "mb": (ref_col, ref_row), "msg": msg
                        })
                        cocotb.log.error(msg)
                        break
                else:
                    continue
                break

        # ── Level 2: block count ────────────────────────────────────────────
        ref_blocks = gm.get("blocks") or []
        if ref_blocks and len(mb_blocks) != len(ref_blocks):
            msg = (
                f"[L2] MB({ref_col},{ref_row}) block count: "
                f"DUT={len(mb_blocks)} REF={len(ref_blocks)}\n"
                f"     p1_consumed={p1_consumed}  "
                f"bd1_before={gm['bd1_byte_offset_before']}  "
                f"delta={p1_consumed - gm['bd1_byte_offset_before']}"
            )
            failures.append({"label": "L2_COUNT", "mb": (ref_col, ref_row), "msg": msg})
            cocotb.log.error(msg)
        else:
            # ── Level 2: has_coeff ──────────────────────────────────────────
            for bi, (db, rb) in enumerate(zip(mb_blocks, ref_blocks)):
                if db["has_coeff"] != bool(rb["has_coeff"]):
                    msg = (
                        f"[L2] MB({ref_col},{ref_row}) "
                        f"block seq={db['seq']} has_coeff: "
                        f"DUT={db['has_coeff']} REF={rb['has_coeff']}\n"
                        f"     p1_consumed={p1_consumed}  "
                        f"bd1_before={gm['bd1_byte_offset_before']}  "
                        f"bd1_after_ref={rb.get('bd1_byte_offset_after')}  "
                        f"delta={p1_consumed - gm['bd1_byte_offset_before']}"
                    )
                    failures.append({
                        "label": "L2_HC",
                        "mb": (ref_col, ref_row), "seq": bi, "msg": msg
                    })
                    cocotb.log.error(msg)

            # ── Level 3: coefficients ───────────────────────────────────────
            for bi, (db, rb) in enumerate(zip(mb_blocks, ref_blocks)):
                rc = rb.get("raw_coeffs", [])
                for ci, (dv, rv) in enumerate(zip(db["coeffs"], rc)):
                    if dv != rv:
                        msg = (
                            f"[L3] MB({ref_col},{ref_row}) "
                            f"block seq={db['seq']} coeff[{ci}]: "
                            f"DUT={dv} REF={rv}\n"
                            f"     DUT: {db['coeffs']}\n"
                            f"     REF: {rc}"
                        )
                        failures.append({
                            "label": "L3_COEFF",
                            "mb": (ref_col, ref_row), "seq": bi, "msg": msg
                        })
                        cocotb.log.error(msg)
                        break

        # ── Level 4: IDCT residuals ─────────────────────────────────────────
        ref_luma   = gm.get("luma")   or []
        ref_chroma = gm.get("chroma") or []

        if ref_luma and dut_luma:
            for r in range(16):
                for c in range(16):
                    if dut_luma[r][c] != ref_luma[r][c]:
                        msg = (
                            f"[L4] MB({ref_col},{ref_row}) "
                            f"luma[{r}][{c}]: "
                            f"DUT={dut_luma[r][c]} REF={ref_luma[r][c]}"
                        )
                        failures.append({
                            "label": "L4_LUMA",
                            "mb": (ref_col, ref_row), "msg": msg
                        })
                        cocotb.log.error(msg)
                        break
                else:
                    continue
                break

        if ref_chroma and dut_chroma:
            for p in range(2):
                plane = "U" if p == 0 else "V"
                for r in range(8):
                    for c in range(8):
                        if dut_chroma[p][r][c] != ref_chroma[p][r][c]:
                            msg = (
                                f"[L4] MB({ref_col},{ref_row}) "
                                f"chroma_{plane}[{r}][{c}]: "
                                f"DUT={dut_chroma[p][r][c]} "
                                f"REF={ref_chroma[p][r][c]}"
                            )
                            failures.append({
                                "label": "L4_CHROMA",
                                "mb": (ref_col, ref_row), "msg": msg
                            })
                            cocotb.log.error(msg)
                            break
                    else:
                        continue
                    break

        # ── Level 5: pixels ─────────────────────────────────────────────────
        for (dut_pix, ref_pix, lbl, rows, cols) in [
            (dut_ypix,  gm.get("y_pixels"),  "Y",  16, 16),
            (dut_cbpix, gm.get("cb_pixels"), "Cb",  8,  8),
            (dut_crpix, gm.get("cr_pixels"), "Cr",  8,  8),
        ]:
            if not ref_pix or dut_pix is None:
                continue
            done = False
            for r in range(rows):
                for c in range(cols):
                    if dut_pix[r][c] != ref_pix[r][c]:
                        msg = (
                            f"[L5] MB({ref_col},{ref_row}) "
                            f"{lbl}[{r}][{c}]: "
                            f"DUT={dut_pix[r][c]} REF={ref_pix[r][c]}"
                        )
                        failures.append({
                            "label": f"L5_{lbl}",
                            "mb": (ref_col, ref_row), "msg": msg
                        })
                        cocotb.log.error(msg)
                        done = True
                        break
                if done:
                    break

        # ── Progress log ────────────────────────────────────────────────────
        cocotb.log.info(
            f"  {'✓' if not any(f.get('mb') == (ref_col,ref_row) for f in failures) else '✗'}"
            f" MB({ref_col:3d},{ref_row:3d})"
            f"  ymode={dut_ymode} skip={int(dut_skip)}"
            f"  p0={p0_consumed}B p1={p1_consumed}B"
        )


# ---------------------------------------------------------------------------
# Main test
# ---------------------------------------------------------------------------
@test.module("VpAteTest")
@cocotb.test()
async def test_golden_mb_integrity(dut):
    """
    Bit-by-bit VP8 decoder integrity test using golden.json.

    - Uses golden["frame_data"] as raw VP8 bytes (no IVF reading).
    - Splits at golden["frame"]["part1_off"] into p0 / p1.
    - BD0 and BD1 bool streams checked bit by bit (prob + decoded bit).
    - Every MB checked: header, has_coeff, coefficients, residuals, pixels.
    """
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())

    if not os.path.exists(_GOLDEN_PATH):
        raise FileNotFoundError(f"golden.json not found at {_GOLDEN_PATH}")

    with open(_GOLDEN_PATH) as f:
        golden = json.load(f)

    gframe    = golden["frame"]
    gbd0_bits = golden.get("bd0", [])
    gbd1_bits = golden.get("bd1", [])
    gmbs      = golden.get("macroblocks", [])
    frame_data = bytes(golden["frame_data"])
    part1_off  = gframe["part1_off"]

    p0_bytes  = frame_data[:part1_off]
    p1_bytes  = frame_data[part1_off:]
    p0_total  = len(p0_bytes)
    p1_total  = len(p1_bytes)

    cocotb.log.info(
        f"Golden: {gframe['width']}×{gframe['height']}  "
        f"{len(gmbs)} MBs  part1_off={part1_off}"
    )
    cocotb.log.info(
        f"  bd0 bits={len(gbd0_bits)}  bd1 bits={len(gbd1_bits)}"
    )
    cocotb.log.info(f"  p0={p0_total}B  p1={p1_total}B")

    assert p0_total > 0, "p0 is empty — check part1_off"
    assert p1_total > 0, "p1 is empty — check part1_off"

    await _reset(dut)

    failures  : list = []
    block_log : list = []

    # ── Launch all monitors before streaming so no bits are missed ───────────
    bd0_task = cocotb.start_soon(
        _bd_monitor(dut,
                    dut.bd0_bit_valid, dut.bd0_bit_prob, dut.bd0_bit_value,
                    gbd0_bits, "BD0", failures)
    )
    bd1_task = cocotb.start_soon(
        _bd_monitor(dut,
                    dut.bd1_bit_valid, dut.bd1_bit_prob, dut.bd1_bit_value,
                    gbd1_bits, "BD1", failures)
    )
    blk_task = cocotb.start_soon(_block_monitor(dut, block_log))
    mb_task  = cocotb.start_soon(
        _mb_monitor(dut, gmbs, block_log, p0_total, p1_total, failures)
    )

    # ── Start streaming ──────────────────────────────────────────────────────
    p0_task = cocotb.start_soon(
        _stream(dut, dut.p0_data, dut.p0_valid, dut.p0_ready, p0_bytes, "P0")
    )
    p1_task = cocotb.start_soon(
        _stream(dut, dut.p1_data, dut.p1_valid, dut.p1_ready, p1_bytes, "P1")
    )

    # ── Wait for frame_done or bd0 early-exit ───────────────────────────────
    TIMEOUT    = 5_000_000
    frame_done = False

    for cycle in range(TIMEOUT):
        await RisingEdge(dut.clk)

        if _r(dut.frame_done):
            frame_done = True
            cocotb.log.info(f"frame_done at cycle {cycle}.")
            break

        # Stop early if BD0 already diverged — subsequent output is noise
        bd0_fails = [f for f in failures if "BD0" in f["label"]]
        if len(bd0_fails) >= 3:
            cocotb.log.warning(
                "3+ BD0 mismatches — stopping early. "
                "Fix BD0 before investigating downstream failures."
            )
            break

    # ── Cancel all tasks ─────────────────────────────────────────────────────
    for t in (bd0_task, bd1_task, blk_task, mb_task, p0_task, p1_task):
        t.cancel()
        try: await t
        except: pass

    # ── Final report ────────────────────────────────────────────────────────
    sep = "═" * 68
    bd0_fails = [f for f in failures if "BD0" in f["label"]]
    bd1_fails = [f for f in failures if "BD1" in f["label"]]
    l1_fails  = [f for f in failures if f["label"].startswith("L1")]
    l2_fails  = [f for f in failures if f["label"].startswith("L2")]
    l3_fails  = [f for f in failures if f["label"].startswith("L3")]
    l4_fails  = [f for f in failures if f["label"].startswith("L4")]
    l5_fails  = [f for f in failures if f["label"].startswith("L5")]

    if not failures and frame_done:
        cocotb.log.info(f"{sep}")
        cocotb.log.info("ALL CHECKS PASSED")
        cocotb.log.info(f"{sep}")
        return

    cocotb.log.error(f"{sep}")
    cocotb.log.error(
        f"SUMMARY: BD0={len(bd0_fails)} BD1={len(bd1_fails)} "
        f"L1={len(l1_fails)} L2={len(l2_fails)} "
        f"L3={len(l3_fails)} L4={len(l4_fails)} L5={len(l5_fails)}"
    )

    # Print first failure of each category
    for cat, lst in [("BD0", bd0_fails), ("BD1", bd1_fails),
                     ("L1",  l1_fails),  ("L2",  l2_fails),
                     ("L3",  l3_fails),  ("L4",  l4_fails),
                     ("L5",  l5_fails)]:
        if lst:
            cocotb.log.error(f"  First {cat}: {lst[0]['msg']}")

    # Root-cause narrative
    cocotb.log.error(f"{sep}")
    if bd0_fails:
        first = bd0_fails[0]
        cocotb.log.error(
            f"ROOT CAUSE → BD0 diverged at bit {first['idx']}.\n"
            f"  Everything from this bit onward is wrong.\n"
            f"  Cross-reference golden['bd0'][{first['idx']}] to find\n"
            f"  which syntax element this bit belongs to:\n"
            f"    Each MB consumes roughly:\n"
            f"      1 bit  : skip_coeff\n"
            f"      2-4 bits: ymode tree\n"
            f"      0 or ~64 bits: sub_modes (BPred only)\n"
            f"      1-3 bits: uvmode tree\n"
            f"  Divide {first['idx']} by average bits/MB to estimate\n"
            f"  which MB and which field first diverged."
        )
    elif bd1_fails:
        first = bd1_fails[0]
        cocotb.log.error(
            f"ROOT CAUSE → BD1 diverged at bit {first['idx']}.\n"
            f"  BD0 correct — header parsing is fine.\n"
            f"  TokenDecoder probability table or tree walk is wrong.\n"
            f"  Expected prob={first['ref_prob']} bit={first['ref_bit']}.\n"
            f"  DUT produced  prob={first['dut_prob']} bit={first['dut_bit']}."
        )
    elif l1_fails and not bd0_fails:
        cocotb.log.error(
            "ROOT CAUSE → Header fields wrong but BD0 bit stream correct.\n"
            "  BD0 produces right bits; HeaderParser misinterprets them.\n"
            "  Check tree arrays, probability table indexing, or leaf decoding."
        )
    elif l2_fails and not bd1_fails:
        cocotb.log.error(
            "ROOT CAUSE → has_coeff wrong but BD1 bit stream correct.\n"
            "  TokenDecoder receives right bits but misinterprets them.\n"
            "  Check token tree walk and EOB detection."
        )
    elif l3_fails:
        cocotb.log.error(
            "ROOT CAUSE → Coefficients wrong but has_coeff correct.\n"
            "  Dequantization is wrong. Check quantizer values\n"
            f"  ydc={gframe['ydc']} yac={gframe['yac']} "
            f"y2dc={gframe['y2dc']} y2ac={gframe['y2ac']} "
            f"uvdc={gframe['uvdc']} uvac={gframe['uvac']}."
        )
    elif l4_fails:
        cocotb.log.error(
            "ROOT CAUSE → IDCT/IWHT output wrong but coefficients correct.\n"
            "  Check the transform arithmetic."
        )
    elif l5_fails:
        cocotb.log.error(
            "ROOT CAUSE → Final pixels wrong but residuals correct.\n"
            "  Predictor is wrong for the failing MB's intra mode."
        )
    cocotb.log.error(f"{sep}")

    raise AssertionError(
        f"{len(failures)} failure(s) — first: {failures[0]['msg']}"
    )
