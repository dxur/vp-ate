"""
test_header_parser.py — Isolated HeaderParser test driven by golden.json.

Uses golden["macroblocks"][i]["bd0_idx_before"] as the exact index into
golden["bd0"] where each MB's skip_coeff bit lives. No heuristic scanning.

For every MB:
  1. Seek to bd0_idx_before in the global bd0 array.
  2. Serve bits as a stub BoolDecoder, checking every prob.
  3. After valid, verify header fields.
  4. Confirm the parser consumed exactly
     (next_mb.bd0_idx_before - this_mb.bd0_idx_before) bits.

Maintains left/above neighbour state exactly as VpAte does.
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

# ---------------------------------------------------------------------------
# Mode maps
# ---------------------------------------------------------------------------
_YMODE  = {"DcPred": 0, "VPred": 1, "HPred": 2, "TmPred": 3, "BPred": 4}
_UVMODE = {"DcPred": 0, "VPred": 1, "HPred": 2, "TmPred": 3}
_BMODE  = {
    "BDcPred": 0, "BTmPred": 1, "BVePred": 2, "BHePred": 3,
    "BLdPred": 4, "BRdPred": 5, "BVrPred": 6, "BVlPred": 7,
    "BHdPred": 8, "BHuPred": 9,
}

def _ym(v):  return _YMODE[v]  if isinstance(v, str) else int(v)
def _uvm(v): return _UVMODE[v] if isinstance(v, str) else int(v)
def _bm(v):  return _BMODE[v]  if isinstance(v, str) else int(v)

# ---------------------------------------------------------------------------
# Header packing — 72-bit flat format for MacroblockParserTest:
#   [71]    valid
#   [70]    mb_skip_coeff
#   [69:67] intra_y_mode
#   [66:64] intra_uv_mode
#   [63:0]  sub_modes[0][0]..[3][3] (4 bits each, row-major, MSB first)
# ---------------------------------------------------------------------------
def _pack_header(h):
    if h is None:
        return 0
    val  = (1 << 71)
    val |= (int(h.get("mb_skip_coeff", False)) << 70)
    val |= (_ym(h["intra_y_mode"])  << 67)
    val |= (_uvm(h["intra_uv_mode"]) << 64)
    sm = h.get("sub_modes") or [[0]*4 for _ in range(4)]
    for y in range(4):
        for x in range(4):
            bm = _bm(sm[y][x]) if (sm[y][x] is not None
                                    and isinstance(sm[y][x], (str, int))) else 0
            val |= (bm & 0xF) << (60 - (y*4+x)*4)
    return val

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _r(sig):
    try:    return int(sig.value)
    except: return None

async def _reset(dut, cycles=4):
    dut.rst.value               = 0
    dut.bd_ready.value          = 0
    dut.bd_data_valid.value     = 0
    dut.bd_data.value           = 0
    dut.frame_ctx_valid.value   = 0
    dut.left_valid.value        = 0
    dut.above_valid.value       = 0
    dut.left_header.value       = 0
    dut.above_header.value      = 0
    dut.x.value                 = 0
    dut.y.value                 = 0
    dut.parser_ready.value      = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 1
    await RisingEdge(dut.clk)

def _drive_ctx(dut, gframe):
    def _u16(v): return v & 0xFFFF
    dut.frame_ctx_valid.value           = 1
    dut.frame_ctx_width.value           = gframe["width"]
    dut.frame_ctx_height.value          = gframe["height"]
    dut.frame_ctx_mb_width.value        = (gframe["width"]  + 15) // 16
    dut.frame_ctx_mb_height.value       = (gframe["height"] + 15) // 16
    dut.frame_ctx_part1_off.value       = gframe["part1_off"]
    dut.frame_ctx_h_scale.value         = 0
    dut.frame_ctx_v_scale.value         = 0
    dut.frame_ctx_ydc.value             = _u16(gframe["ydc"])
    dut.frame_ctx_yac.value             = _u16(gframe["yac"])
    dut.frame_ctx_y2dc.value            = _u16(gframe["y2dc"])
    dut.frame_ctx_y2ac.value            = _u16(gframe["y2ac"])
    dut.frame_ctx_uvdc.value            = _u16(gframe["uvdc"])
    dut.frame_ctx_uvac.value            = _u16(gframe["uvac"])
    dut.frame_ctx_mb_no_skip_coeff.value = int(gframe["mb_no_skip_coeff"])
    dut.frame_ctx_prob_skip_false.value  = gframe["prob_skip_false"]

def _read_header(dut):
    return (
        _r(dut.header_intra_y_mode),
        _r(dut.header_intra_uv_mode),
        bool(_r(dut.header_mb_skip_coeff)),
        [[_r(dut.header_sub_modes[y][x]) for x in range(4)] for y in range(4)]
    )

# ---------------------------------------------------------------------------
# BD stub: serve bits from bd0_bits[start_idx..], checking probs.
# Returns when parser asserts valid or on timeout.
# Returns (next_idx, timed_out).
# ---------------------------------------------------------------------------
async def _serve_mb(dut, bd0_bits, start_idx, failures, mb_label,
                    expected_bits, timeout=100_000):
    idx = start_idx
    end_idx = start_idx + expected_bits if expected_bits else start_idx + 200

    for _ in range(timeout):
        await RisingEdge(dut.clk)

        if _r(dut.valid):
            return idx, False

        if not _r(dut.bd_valid):
            continue

        dut_prob = _r(dut.bd_prob)

        if idx >= len(bd0_bits):
            msg = (f"{mb_label}: over-read — requested bd0[{idx}] but "
                   f"stream has {len(bd0_bits)} bits")
            failures.append({"mb": mb_label, "idx": idx, "msg": msg,
                              "type": "overread"})
            cocotb.log.error(msg)
            dut.bd_ready.value = 1
            await RisingEdge(dut.clk)
            dut.bd_ready.value = 0
            dut.bd_data.value = 0
            dut.bd_data_valid.value = 1
            await RisingEdge(dut.clk)
            dut.bd_data_valid.value = 0
            idx += 1
            continue

        ref_prob = bd0_bits[idx]["prob"]
        ref_bit  = int(bd0_bits[idx]["bit"])

        if dut_prob != ref_prob:
            msg = (
                f"{mb_label}: PROB MISMATCH at bd0[{idx}] "
                f"(bit {idx - start_idx} of this MB):\n"
                f"  Parser prob={dut_prob}  REF prob={ref_prob}  bit={ref_bit}"
            )
            failures.append({"mb": mb_label, "idx": idx, "msg": msg,
                              "type": "prob",
                              "dut_prob": dut_prob, "ref_prob": ref_prob})
            cocotb.log.error(msg)

        # Accept and respond
        dut.bd_ready.value = 1
        await RisingEdge(dut.clk)
        dut.bd_ready.value = 0
        dut.bd_data.value       = ref_bit
        dut.bd_data_valid.value = 1
        await RisingEdge(dut.clk)
        dut.bd_data_valid.value = 0
        dut.bd_data.value       = 0

        idx += 1

    msg = f"{mb_label}: TIMEOUT — parser never asserted valid"
    failures.append({"mb": mb_label, "msg": msg, "type": "timeout"})
    cocotb.log.error(msg)
    return idx, True

# ---------------------------------------------------------------------------
# Header checker
# ---------------------------------------------------------------------------
def _check_header(dut, gm, failures):
    mb_label = f"MB({gm['col']},{gm['row']})"
    dut_ym, dut_uvm, dut_skip, dut_sm = _read_header(dut)
    ref_ym   = _ym(gm["intra_y_mode"])
    ref_uvm  = _uvm(gm["intra_uv_mode"])
    ref_skip = bool(gm["mb_skip_coeff"])
    ok = True

    if dut_ym != ref_ym:
        msg = f"{mb_label} ymode: DUT={dut_ym} REF={ref_ym}"
        failures.append({"mb": mb_label, "field": "ymode", "msg": msg})
        cocotb.log.error(f"[HDR] {msg}")
        ok = False

    if dut_uvm != ref_uvm:
        msg = f"{mb_label} uvmode: DUT={dut_uvm} REF={ref_uvm}"
        failures.append({"mb": mb_label, "field": "uvmode", "msg": msg})
        cocotb.log.error(f"[HDR] {msg}")
        ok = False

    if dut_skip != ref_skip:
        msg = f"{mb_label} skip: DUT={dut_skip} REF={ref_skip}"
        failures.append({"mb": mb_label, "field": "skip", "msg": msg})
        cocotb.log.error(f"[HDR] {msg}")
        ok = False

    if gm["intra_y_mode"] == "BPred" and gm.get("sub_modes"):
        ref_sm = gm["sub_modes"]
        for y in range(4):
            for x in range(4):
                rv = _bm(ref_sm[y][x]) if isinstance(ref_sm[y][x], str) \
                     else int(ref_sm[y][x])
                if dut_sm[y][x] != rv:
                    msg = (f"{mb_label} sub_modes[{y}][{x}]: "
                           f"DUT={dut_sm[y][x]} REF={rv}")
                    failures.append({"mb": mb_label,
                                     "field": f"sm[{y}][{x}]", "msg": msg})
                    cocotb.log.error(f"[HDR] {msg}")
                    ok = False
    return ok

# ---------------------------------------------------------------------------
# Main test
# ---------------------------------------------------------------------------
@test.module("MacroblockParserTest")
@cocotb.test()
async def test_header_parser_golden(dut):
    """
    Feed each MB's bd0 bits directly into HeaderParser using
    bd0_idx_before from golden as the exact stream position.
    Checks every prob and every header field.
    """
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())

    if not os.path.exists(_GOLDEN_PATH):
        raise FileNotFoundError(f"golden.json not found at {_GOLDEN_PATH}")

    with open(_GOLDEN_PATH) as f:
        g = json.load(f)

    gframe   = g["frame"]
    gmbs     = g["macroblocks"]
    bd0_bits = g["bd0"]
    mb_cols  = (gframe["width"]  + 15) // 16

    cocotb.log.info(
        f"Golden: {gframe['width']}×{gframe['height']}  "
        f"{len(gmbs)} MBs  bd0 bits={len(bd0_bits)}"
    )

    # Verify bd0_idx_before is present
    if "bd0_idx_before" not in gmbs[0]:
        raise AssertionError(
            "golden.json missing bd0_idx_before on macroblocks — "
            "please regenerate golden with this field."
        )

    await _reset(dut)
    _drive_ctx(dut, gframe)
    await RisingEdge(dut.clk)

    # Neighbour state
    above_hdrs = [None] * mb_cols
    left_hdr   = None
    failures   = []

    for i, gm in enumerate(gmbs):
        col      = gm["col"]
        row      = gm["row"]
        mb_label = f"MB({col},{row})"

        # Exact bd0 start index from golden
        start_idx = gm["bd0_idx_before"]

        # Expected bit count = next MB's start - this MB's start
        if i + 1 < len(gmbs):
            expected_bits = gmbs[i+1]["bd0_idx_before"] - start_idx
        else:
            expected_bits = len(bd0_bits) - start_idx

        # Drive neighbours
        dut.x.value = col
        dut.y.value = row
        if left_hdr is not None:
            dut.left_valid.value  = 1
            dut.left_header.value = _pack_header(left_hdr)
        else:
            dut.left_valid.value  = 0
            dut.left_header.value = 0

        if above_hdrs[col] is not None:
            dut.above_valid.value  = 1
            dut.above_header.value = _pack_header(above_hdrs[col])
        else:
            dut.above_valid.value  = 0
            dut.above_header.value = 0

        dut.parser_ready.value = 1
        await RisingEdge(dut.clk)

        # Serve bits
        end_idx, timed_out = await _serve_mb(
            dut, bd0_bits, start_idx, failures, mb_label, expected_bits
        )

        if timed_out:
            break

        bits_used = end_idx - start_idx

        # Verify bit count
        if bits_used != expected_bits:
            msg = (f"{mb_label}: consumed {bits_used} bits but "
                   f"expected {expected_bits} "
                   f"(bd0[{start_idx}..{start_idx+expected_bits-1}])")
            failures.append({"mb": mb_label, "msg": msg, "type": "bitcount"})
            cocotb.log.error(f"[CNT] {msg}")

        await RisingEdge(dut.clk)
        hdr_ok = _check_header(dut, gm, failures)

        # Accept header
        dut.parser_ready.value = 1
        await RisingEdge(dut.clk)
        dut.parser_ready.value = 0
        await RisingEdge(dut.clk)

        # Update neighbour state
        above_hdrs[col] = gm
        left_hdr = None if col == mb_cols - 1 else gm

        status = "✓" if hdr_ok and bits_used == expected_bits and not any(
            f.get("mb") == mb_label and f.get("type") == "prob"
            for f in failures
        ) else "✗"

        cocotb.log.info(
            f"  {status} {mb_label}  "
            f"ymode={_ym(gm['intra_y_mode']):1d}  "
            f"bits={bits_used}/{expected_bits}  "
            f"bd0[{start_idx}:{end_idx}]"
        )

        # Stop early on prob failures
        prob_fails = [f for f in failures if f.get("type") == "prob"]
        if len(prob_fails) >= 5:
            cocotb.log.warning(
                f"5+ prob mismatches — stopping at {mb_label}."
            )
            break

    # Report
    sep = "═" * 64
    prob_fails    = [f for f in failures if f.get("type") == "prob"]
    hdr_fails     = [f for f in failures if "field" in f]
    count_fails   = [f for f in failures if f.get("type") == "bitcount"]
    timeout_fails = [f for f in failures if f.get("type") == "timeout"]

    if not failures:
        cocotb.log.info(f"{sep}")
        cocotb.log.info(
            f"ALL {len(gmbs)} MBs PASSED — "
            f"prob sequence and headers correct."
        )
        cocotb.log.info(f"{sep}")
        return

    cocotb.log.error(f"{sep}")
    cocotb.log.error(
        f"FAILURES: prob={len(prob_fails)}  header={len(hdr_fails)}  "
        f"bitcount={len(count_fails)}  timeout={len(timeout_fails)}"
    )
    for f in (prob_fails + hdr_fails + count_fails)[:8]:
        cocotb.log.error(f"  {f['msg']}")

    if prob_fails:
        first = prob_fails[0]
        cocotb.log.error(
            f"\nROOT CAUSE: prob mismatch at bd0[{first['idx']}] "
            f"in {first['mb']}.\n"
            f"  Parser prob={first['dut_prob']}  REF={first['ref_prob']}\n"
            f"  The bit offset is exact from bd0_idx_before — "
            f"this IS the wrong prob.\n"
            f"  Identify the syntax element by counting from the MB start:\n"
            f"    bit 0     : skip_coeff  (prob=prob_skip_false)\n"
            f"    bits 1..N : ymode tree  (KF_YMODE_PROB)\n"
            f"    if BPred  : 16 sub-mode tree walks (KF_BMODE_PROB)\n"
            f"    last bits : uvmode tree (KF_UV_MODE_PROB)\n"
            f"  bd0[{first['idx']}] is bit "
            f"{first['idx'] - gmbs[0]['bd0_idx_before']} from MBHP start."
        )
    elif count_fails:
        cocotb.log.error(
            "\nROOT CAUSE: wrong number of bits consumed.\n"
            "  Parser terminated early (leaf reached wrong node) or\n"
            "  continued past leaf (leaf detection broken)."
        )
    elif hdr_fails:
        cocotb.log.error(
            "\nROOT CAUSE: correct probs, correct bit count, wrong field values.\n"
            "  Tree walk is correct but leaf→mode mapping is wrong.\n"
            "  Check IntraMBMode/IntraBMode enum values vs tree leaf values."
        )

    cocotb.log.error(f"{sep}")
    raise AssertionError(
        f"{len(failures)} failure(s) — first: {failures[0]['msg']}"
    )
