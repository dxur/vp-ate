"""
test_frame_parser.py — Isolated FrameHeaderParser test driven by golden.json.

Feeds the bd0 bit stream directly from golden["bd0"] into the FHP's
BoolDecoder interface — bypassing the real BoolDecoder entirely.
This lets us verify that FHP requests exactly the right (prob, bit) pairs
in exactly the right order, independent of any BoolDecoder timing issue.

Strategy:
  - Stream the 10 raw header bytes from golden["frame_data"][0:10] into
    raw_data/raw_valid/raw_ready.
  - For every bd.valid pulse from FHP, check that bd.prob matches
    golden["bd0"][idx]["prob"], then respond with golden["bd0"][idx]["bit"].
  - After FHP asserts done, verify all ctx fields against golden["frame"].

DUT: FrameParserTest (flat wrapper around FrameHeaderParser).

Ports used:
  raw_data, raw_valid, raw_ready
  bd_valid, bd_prob, bd_ready, bd_data_valid, bd_data_ready, bd_data
  ctx_valid, ctx_width, ctx_height, ctx_mb_width, ctx_mb_height,
  ctx_ydc, ctx_yac, ctx_y2dc, ctx_y2ac, ctx_uvdc, ctx_uvac,
  ctx_mb_no_skip_coeff, ctx_prob_skip_false, ctx_part1_off
  done
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


def _load_golden():
    if not os.path.exists(_GOLDEN_PATH):
        raise FileNotFoundError(f"golden.json not found at {_GOLDEN_PATH}")
    with open(_GOLDEN_PATH) as f:
        return json.load(f)


def _r(sig):
    try:    return int(sig.value)
    except: return None


async def _reset(dut, cycles=4):
    dut.rst.value          = 0
    dut.raw_data.value     = 0
    dut.raw_valid.value    = 0
    dut.bd_ready.value     = 0
    dut.bd_data_valid.value = 0
    dut.bd_data.value      = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 1
    await RisingEdge(dut.clk)


# ---------------------------------------------------------------------------
# Stream the 10 raw header bytes
# ---------------------------------------------------------------------------
async def _stream_raw(dut, raw_bytes, timeout=1000):
    """Feed raw_bytes into raw_data/raw_valid, respect raw_ready."""
    for i, b in enumerate(raw_bytes):
        dut.raw_data.value  = b
        dut.raw_valid.value = 1
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            if _r(dut.raw_ready):
                break
        else:
            raise TimeoutError(f"raw_ready never asserted for byte {i}")
    dut.raw_valid.value = 0


# ---------------------------------------------------------------------------
# BD stub: respond to every bd.valid with the golden bit, check prob
# ---------------------------------------------------------------------------
async def _bd_stub(dut, bd0_bits, failures, result_dict):
    """
    Monitors bd_valid. On each assertion:
      1. Checks bd_prob against golden["bd0"][idx]["prob"].
      2. Responds with golden["bd0"][idx]["bit"] via bd_data_valid/bd_data.
    Appends to failures on any prob mismatch.
    Records every (prob, bit) the FHP requested into a log.
    Updates result_dict["idx"] with the current bit index.
    """
    idx = 0
    result_dict["idx"] = 0
    while True:
        await RisingEdge(dut.clk)

        if not _r(dut.bd_valid):
            continue

        # FHP is requesting a bool decode
        dut_prob = _r(dut.bd_prob)

        if idx >= len(bd0_bits):
            failures.append({
                "idx": idx,
                "msg": f"FHP requested bit {idx} but golden only has "
                       f"{len(bd0_bits)} bd0 bits"
            })
            cocotb.log.error(failures[-1]["msg"])
            idx += 1
            result_dict["idx"] = idx
            # respond with 0 to keep FHP moving
            dut.bd_ready.value      = 1
            await RisingEdge(dut.clk)
            dut.bd_ready.value      = 0
            dut.bd_data.value       = 0
            dut.bd_data_valid.value = 1
            await RisingEdge(dut.clk)
            dut.bd_data_valid.value = 0
            continue

        ref_prob = bd0_bits[idx]["prob"]
        ref_bit  = int(bd0_bits[idx]["bit"])

        if dut_prob != ref_prob:
            msg = (
                f"PROB MISMATCH at bd0 index {idx}:\n"
                f"  FHP requested prob={dut_prob}\n"
                f"  REF expected  prob={ref_prob}  bit={ref_bit}\n"
                f"  First {idx} prob/bit pairs were correct."
            )
            failures.append({"idx": idx, "msg": msg,
                              "dut_prob": dut_prob, "ref_prob": ref_prob})
            cocotb.log.error(msg)

        # Accept the request (bd_ready)
        dut.bd_ready.value = 1
        await RisingEdge(dut.clk)
        dut.bd_ready.value = 0

        # Deliver the golden bit (bd_data_valid + bd_data)
        dut.bd_data.value       = ref_bit
        dut.bd_data_valid.value = 1
        await RisingEdge(dut.clk)
        dut.bd_data_valid.value = 0
        dut.bd_data.value       = 0

        cocotb.log.debug(
            f"  bd0[{idx:4d}] prob={dut_prob:3d} bit={ref_bit}"
            + ("" if dut_prob == ref_prob else f"  ← PROB WRONG (ref={ref_prob})")
        )
        idx += 1
        result_dict["idx"] = idx


# ---------------------------------------------------------------------------
# Wait for done with timeout
# ---------------------------------------------------------------------------
async def _wait_done(dut, timeout=200_000):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if _r(dut.done):
            return True
    return False


# ---------------------------------------------------------------------------
# ctx field verification
# ---------------------------------------------------------------------------
def _check_ctx(dut, gframe, failures):
    checks = [
        ("width",            _r(dut.ctx_width),            gframe["width"]),
        ("height",           _r(dut.ctx_height),           gframe["height"]),
        ("mb_width",         _r(dut.ctx_mb_width),         (gframe["width"]  + 15) // 16),
        ("mb_height",        _r(dut.ctx_mb_height),        (gframe["height"] + 15) // 16),
        ("ydc",              _r(dut.ctx_ydc),              gframe["ydc"]),
        ("yac",              _r(dut.ctx_yac),              gframe["yac"]),
        ("y2dc",             _r(dut.ctx_y2dc),             gframe["y2dc"]),
        ("y2ac",             _r(dut.ctx_y2ac),             gframe["y2ac"]),
        ("uvdc",             _r(dut.ctx_uvdc),             gframe["uvdc"]),
        ("uvac",             _r(dut.ctx_uvac),             gframe["uvac"]),
        ("prob_skip_false",  _r(dut.ctx_prob_skip_false),  gframe["prob_skip_false"]),
        ("mb_no_skip_coeff", _r(dut.ctx_mb_no_skip_coeff),int(gframe["mb_no_skip_coeff"])),
        ("part1_off",        _r(dut.ctx_part1_off),        gframe["part1_off"]),
    ]
    for name, dut_val, ref_val in checks:
        # ctx fields are raw logic — signed fields need conversion
        if name in ("ydc", "yac", "y2dc", "y2ac", "uvdc", "uvac"):
            if dut_val is not None and dut_val >= 0x8000:
                dut_val = dut_val - 0x10000
        if dut_val != ref_val:
            msg = f"ctx.{name}: DUT={dut_val}  REF={ref_val}"
            failures.append({"field": name, "msg": msg})
            cocotb.log.error(f"[CTX] {msg}")
        else:
            cocotb.log.info(f"  ✓ ctx.{name} = {dut_val}")


# ---------------------------------------------------------------------------
# Main test
# ---------------------------------------------------------------------------
@test.module("FrameParserTest")
@cocotb.test()
async def test_frame_parser_golden(dut):
    """
    Feed golden bd0 bits directly into FHP as a stub BoolDecoder.
    Check every prob FHP requests against golden["bd0"].
    After done, verify all ctx fields against golden["frame"].
    """
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())

    g         = _load_golden()
    gframe    = g["frame"]
    bd0_bits  = g["bd0"]
    frame_data = bytes(g["frame_data"])
    raw_bytes  = frame_data[:10]   # first 10 bytes: tag + start code + dims

    cocotb.log.info(
        f"Golden: {gframe['width']}×{gframe['height']}  "
        f"part1_off={gframe['part1_off']}  "
        f"bd0 bits={len(bd0_bits)}"
    )
    cocotb.log.info(f"Raw header bytes: {list(raw_bytes)}")

    await _reset(dut)

    failures = []
    res = {}

    # Start BD stub before streaming so no bd.valid pulse is missed
    bd_task = cocotb.start_soon(_bd_stub(dut, bd0_bits, failures, res))

    # Stream raw bytes
    await _stream_raw(dut, raw_bytes)

    # Wait for FHP to finish
    done = await _wait_done(dut)

    bd_task.cancel()
    try: await bd_task
    except: pass

    # Report
    sep = "═" * 60
    if not done:
        cocotb.log.error(f"{sep}")
        cocotb.log.error("TIMEOUT — FHP never asserted done.")
        cocotb.log.error(f"{sep}")
        raise AssertionError("FHP never asserted done")

    cocotb.log.info(f"FHP asserted done at bd0 bit index: {res.get('idx')}")
    cocotb.log.info("Checking ctx fields...")
    _check_ctx(dut, gframe, failures)

    if failures:
        cocotb.log.error(f"{sep}")
        cocotb.log.error(f"FAILURES ({len(failures)}):")
        for f in failures:
            cocotb.log.error(f"  {f['msg']}")
        cocotb.log.error(f"{sep}")

        # Root cause summary
        prob_fails = [f for f in failures if "PROB" in f.get("msg", "")]
        ctx_fails  = [f for f in failures if "field" in f]

        if prob_fails:
            first = prob_fails[0]
            cocotb.log.error(
                f"ROOT CAUSE: FHP sent wrong prob at bd0 index {first['idx']}.\n"
                f"  FHP prob={first['dut_prob']}  REF prob={first['ref_prob']}\n"
                f"  This means FHP is using the wrong probability constant\n"
                f"  for whichever syntax element bd0[{first['idx']}] belongs to.\n"
                f"  Count the bits before index {first['idx']} to identify the field:\n"
                f"    2 bits  : color_space + clamping\n"
                f"    1 bit   : segmentation_enabled\n"
                f"    1 bit   : filter_type\n"
                f"    6 bits  : loop_filter_level\n"
                f"    3 bits  : sharpness_level\n"
                f"    1 bit   : loop_filter_adj_enable\n"
                f"    1 bit   : mode_ref_lf_delta_update (if adj_enable=1)\n"
                f"    2 bits  : log2_nbr_of_dct_partitions\n"
                f"    7 bits  : yac_qi\n"
                f"    5 bits  : each delta (flag + 4mag + sign)\n"
                f"    1 bit   : refresh_entropy_probs\n"
                f"    1056 bits max: coeff_prob update flags + new probs\n"
                f"    1 bit   : mb_no_skip_coeff\n"
                f"    8 bits  : prob_skip_false (if mb_no_skip_coeff=1)\n"
                f"\n"
                f"  Most likely cause: S_BD_COEFFPROB reads the update flag\n"
                f"  with prob=128 but should use\n"
                f"  Tables::COEFF_UPDATE_PROBS[plane][band][ctx][tok]."
            )
        elif ctx_fails:
            cocotb.log.error(
                "ROOT CAUSE: Prob sequence correct but ctx fields wrong.\n"
                "  FHP decoded the right bits but computed wrong values.\n"
                "  Check quantizer delta application and field assembly."
            )

        raise AssertionError(
            f"{len(failures)} failure(s) — first: {failures[0]['msg']}"
        )

    cocotb.log.info(f"{sep}")
    cocotb.log.info("ALL CHECKS PASSED — FHP prob sequence and ctx correct.")
    cocotb.log.info(f"{sep}")
