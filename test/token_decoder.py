"""
test_token_decoder_golden.py - replay recorded bd1 bits from golden.json
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


def _r(sig):
    try:    return int(sig.value)
    except: return None


async def _reset(dut, cycles=4):
    dut.rst.value              = 0
    dut.bd_ready.value         = 1
    dut.bd_data_valid.value    = 0
    dut.bd_data.value          = 0
    dut.start.value            = 0
    dut.plane.value            = 0
    dut.complexity.value       = 0
    dut.first_coeff.value      = 0
    dut.dcq.value              = 4
    dut.acq.value              = 4
    dut.coeff_probs_flat.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 1
    await RisingEdge(dut.clk)


async def _run_block(dut, plane, complexity, first_coeff, dcq, acq,
                     cp_flat, bit_log, label, timeout=4000):
    """
    Run one block on the DUT, replaying pre-recorded bits from golden.
    bit_log is a list of {"prob": p, "bit": b} dicts — the exact sequence
    the Rust decoder consumed for this block.
    When the DUT asserts bd_valid we pop the next entry, verify the prob
    matches (optional but catches desync early), and feed the recorded bit.
    """
    dut.plane.value            = plane
    dut.complexity.value       = complexity
    dut.first_coeff.value      = first_coeff
    dut.dcq.value              = dcq & 0xFFFF
    dut.acq.value              = acq & 0xFFFF
    dut.coeff_probs_flat.value = cp_flat

    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    bit_idx = 0

    for _ in range(timeout):
        await RisingEdge(dut.clk)

        if _r(dut.coeff_valid):
            coeffs    = [int(dut.coeffs[i].value.to_signed()) for i in range(16)]
            has_coeff = bool(_r(dut.has_coeff))
            dut.bd_data_valid.value = 0
            return coeffs, has_coeff

        if _r(dut.bd_valid) and not _r(dut.bd_data_valid):
            if bit_idx >= len(bit_log):
                raise ValueError(
                    f"{label}: DUT requested bit #{bit_idx} but golden "
                    f"bit_log only has {len(bit_log)} entries"
                )

            entry    = bit_log[bit_idx]
            dut_prob = _r(dut.bd_prob)
            ref_prob = entry["prob"]
            ref_bit  = entry["bit"]

            # Probability mismatch = wrong context or tree position
            if dut_prob != ref_prob:
                cocotb.log.warning(
                    f"{label} bit[{bit_idx}]: prob mismatch "
                    f"DUT={dut_prob} REF={ref_prob} — feeding ref bit anyway"
                )

            bit_idx += 1
            dut.bd_data.value       = ref_bit
            dut.bd_data_valid.value = 1
            await RisingEdge(dut.clk)
            dut.bd_data_valid.value = 0
            dut.bd_data.value       = 0

    raise TimeoutError(f"{label}: coeff_valid never asserted after {timeout} cycles")


def _make_entry():
    return {
        'y2': False,
        'y':  [False] * 4,
        'uv': [[False] * 2, [False] * 2],
    }


@test.module("TokenDecoderTest")
@cocotb.test()
async def test_token_decoder_golden(dut):
    """
    Drive TokenDecoder by replaying the pre-recorded bd1 bit log from golden.json.
    No re-decoding from raw frame bytes — we feed exactly the bits Rust consumed.
    """
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())

    g        = _load_golden()
    gframe   = g["frame"]
    gmbs     = g["macroblocks"]
    cp_flat  = _build_coeff_probs_flat(gframe["coeff_probs"])
    mb_width = (gframe["width"] + 15) // 16

    # Global bd1 bit log — consumed sequentially across all blocks
    # Each block in the golden records how many bits it consumed; the global
    # log is the concatenation across all blocks in decode order.
    global_bit_log = g.get("bd1", [])
    global_bit_pos = 0  # index into global_bit_log

    await _reset(dut)

    hcv      = [_make_entry() for _ in range(mb_width + 1)]
    prev_row = -1
    total    = 0
    failures = []

    for gm in gmbs:
        col    = gm["col"]
        row    = gm["row"]
        mbx    = col + 1
        blocks = gm.get("blocks") or []

        if row != prev_row:
            hcv[0]   = _make_entry()
            prev_row = row

        luma_left = [hcv[0]['y'][i]              for i in range(4)]
        uv_left   = [[hcv[0]['uv'][p][i] for i in range(2)] for p in range(2)]

        luma_count = 0
        uv_count   = [0, 0]

        for blk in blocks:
            plane = blk["plane"]

            if plane == 1:
                first_coeff = 0
                dcq, acq    = gframe["y2dc"], gframe["y2ac"]
            elif plane in (0, 3):
                first_coeff = 1 if plane == 0 else 0
                dcq, acq    = gframe["ydc"], gframe["yac"]
            else:
                first_coeff = 0
                dcq, acq    = gframe["uvdc"], gframe["uvac"]

            if plane == 1:
                complexity = (1 if hcv[mbx]['y2'] else 0) + (1 if hcv[0]['y2'] else 0)
            elif plane in (0, 3):
                i = luma_count // 4
                j = luma_count % 4
                complexity = (1 if hcv[mbx]['y'][j] else 0) + (1 if luma_left[i] else 0)
            else:
                p   = 0 if uv_count[0] < 4 else 1
                sub = uv_count[p]
                i   = sub // 2
                j   = sub % 2
                complexity = (1 if hcv[mbx]['uv'][p][j] else 0) + (1 if uv_left[p][i] else 0)

            label = f"MB({col},{row}) plane={plane} luma={luma_count}"
            total += 1

            # Slice out this block's bits from the global log.
            # If the golden has per-block bit logs use those; otherwise
            # consume from the global log up to what the block used.
            # The golden structure has bd1_idx_before/after per block which
            # tells us exactly which slice of the global log to use.
            bd1_before = blk.get("bd1_idx_before", global_bit_pos)
            bd1_after  = blk.get("bd1_idx_after",  None)

            if bd1_after is not None:
                bit_log = global_bit_log[bd1_before:bd1_after]
                global_bit_pos = bd1_after
            else:
                # Fallback: give the full remaining log and let the DUT
                # consume what it needs (detected by coeff_valid)
                bit_log = global_bit_log[global_bit_pos:]

            try:
                got_coeffs, got_has = await _run_block(
                    dut, plane, complexity, first_coeff,
                    dcq, acq, cp_flat, bit_log, label
                )
                cocotb.log.info(
                    f"[{label}] decoded successfully. "
                    f"has_coeff={got_has}, coeffs={got_coeffs}"
                )
            except (TimeoutError, ValueError) as e:
                failures.append(f"ERROR {label}: {e}")
                cocotb.log.error(failures[-1])
                break

            # Update has_coeff_vec
            if plane == 1:
                hcv[mbx]['y2'] = got_has
                hcv[0]['y2']   = got_has
            elif plane in (0, 3):
                i = luma_count // 4
                j = luma_count % 4
                hcv[mbx]['y'][j] = got_has
                luma_left[i]     = got_has
                if j == 3:
                    hcv[0]['y'][i] = got_has
                luma_count += 1
            else:
                p   = 0 if uv_count[0] < 4 else 1
                sub = uv_count[p]
                i   = sub // 2
                j   = sub % 2
                hcv[mbx]['uv'][p][j] = got_has
                uv_left[p][i]        = got_has
                if j == 1:
                    hcv[0]['uv'][p][i] = got_has
                uv_count[p] += 1

            ref_has    = bool(blk["has_coeff"])
            ref_coeffs = blk["raw_coeffs"]

            if got_has != ref_has:
                msg = (
                    f"[{label}] has_coeff: DUT={got_has} REF={ref_has}\n"
                    f"  plane={plane} complexity={complexity} "
                    f"first_coeff={first_coeff} dcq={dcq} acq={acq}"
                )
                failures.append(msg)
                cocotb.log.error(msg)
                break

            cocotb.log.info(f"[{label}] has_coeff matches reference.")

            coeff_fail = None
            for ci in range(min(len(ref_coeffs), 16)):
                if got_coeffs[ci] != ref_coeffs[ci]:
                    coeff_fail = (ci, got_coeffs[ci], ref_coeffs[ci])
                    break

            if coeff_fail:
                ci, dv, rv = coeff_fail
                msg = (
                    f"[{label}] coeff[{ci}]: DUT={dv} REF={rv}\n"
                    f"  DUT: {got_coeffs}\n"
                    f"  REF: {ref_coeffs}\n"
                    f"  plane={plane} complexity={complexity} "
                    f"first_coeff={first_coeff} dcq={dcq} acq={acq}"
                )
                failures.append(msg)
                cocotb.log.error(msg)
                break

            cocotb.log.info(f"[{label}] all coefficients match reference.")

            if total % 100 == 0:
                cocotb.log.info(f"  ✓ {total} blocks correct so far...")

    sep = "═" * 64
    if not failures:
        cocotb.log.info(sep)
        cocotb.log.info(
            f"ALL {total} BLOCKS PASSED — TokenDecoder correct for all golden data."
        )
        cocotb.log.info(sep)
    else:
        cocotb.log.error(sep)
        cocotb.log.error(f"FAILED after {total} blocks. First failure:")
        cocotb.log.error(failures[0])
        cocotb.log.error(sep)
        raise AssertionError(failures[0])
