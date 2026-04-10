import json
import os
import cocotb
from cocotb.triggers import RisingEdge
from cocotb.clock import Clock
import test

_HERE        = os.path.dirname(os.path.abspath(__file__))
_ROOT        = os.path.dirname(_HERE)
_GOLDEN_PATH = os.path.join(_ROOT, ".", "golden.json")


class BoolDecoderRef:
    def __init__(self, data: bytes):
        self._buf       = data
        self._pos       = 0
        self._value     = 0
        self._range     = 255
        self._bit_count = 0
        for _ in range(2):
            self._value = ((self._value << 8) | self._read_byte()) & 0xFFFF_FFFF

    def _read_byte(self) -> int:
        if self._pos >= len(self._buf):
            return 0
        b = self._buf[self._pos]
        self._pos += 1
        return b

    def read_bool(self, prob: int) -> int:
        split         = 1 + (((self._range - 1) * prob) >> 8)
        split_shifted = split << 8
        if self._value >= split_shifted:
            bit           = 1
            self._range  -= split
            self._value  -= split_shifted
        else:
            bit           = 0
            self._range   = split
        while self._range < 128:
            self._value     <<= 1
            self._range     <<= 1
            self._bit_count  += 1
            if self._bit_count == 8:
                self._bit_count = 0
                self._value = (self._value | self._read_byte()) & 0xFFFF_FFFF
        return bit


class MemoryModel:
    def __init__(self, dut, data: bytes,
                 req_latency: int = 1, data_latency: int = 1):
        self._dut          = dut
        self._data         = data
        self._pos          = 0
        self._req_latency  = req_latency
        self._data_latency = data_latency

    def start(self):
        return cocotb.start_soon(self._run())

    async def _run(self):
        dut = self._dut
        dut.mem_ready.value      = 0
        dut.mem_data_valid.value = 0
        dut.mem_data.value       = 0
        while True:
            await RisingEdge(dut.clk)
            if dut.mem_valid.value != 1:
                continue
            for _ in range(self._req_latency - 1):
                await RisingEdge(dut.clk)
            dut.mem_ready.value = 1
            await RisingEdge(dut.clk)
            dut.mem_ready.value = 0
            for _ in range(self._data_latency - 1):
                await RisingEdge(dut.clk)
            byte = self._data[self._pos] if self._pos < len(self._data) else 0
            self._pos += 1
            dut.mem_data.value       = byte
            dut.mem_data_valid.value = 1
            while True:
                await RisingEdge(dut.clk)
                if dut.mem_data_ready.value == 1:
                    break
            dut.mem_data_valid.value = 0
            dut.mem_data.value       = 0


async def reset(dut, cycles: int = 3):
    dut.rst.value            = 0
    dut.self_valid.value     = 0
    dut.self_prob.value      = 128
    dut.self_data_ready.value = 0
    dut.mem_ready.value      = 0
    dut.mem_data_valid.value = 0
    dut.mem_data.value       = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 1
    await RisingEdge(dut.clk)


async def wait_ready(dut, timeout: int = 2000):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.self_ready.value == 1:
            return
    raise TimeoutError("DUT never asserted self_ready")


async def decode_one(dut, prob: int, timeout: int = 2000) -> int:
    dut.self_prob.value       = prob
    dut.self_valid.value      = 1
    dut.self_data_ready.value = 1
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.self_data_valid.value == 1:
            bit = int(dut.self_data.value)
            dut.self_valid.value = 0
            await wait_ready(dut, timeout)
            return bit
    raise TimeoutError(f"DUT never produced data_valid for prob={prob}")


async def _teardown(dut, mem_task):
    mem_task.cancel()
    try:    await mem_task
    except: pass
    dut.mem_ready.value      = 0
    dut.mem_data_valid.value = 0
    dut.mem_data.value       = 0


async def run_partition(dut, partition_bytes: bytes,
                        golden_bits: list, label: str,
                        req_lat: int = 1, data_lat: int = 1,
                        max_bits: int = None):
    n = len(golden_bits) if max_bits is None else min(max_bits, len(golden_bits))

    ref = BoolDecoderRef(partition_bytes)

    await reset(dut)
    mem_task = MemoryModel(dut, partition_bytes,
                           req_latency=req_lat,
                           data_latency=data_lat).start()
    await wait_ready(dut)

    for i in range(n):
        golden = golden_bits[i]
        g_prob = golden["prob"]
        g_bit  = golden["bit"]

        # Python reference must agree with golden
        r_bit = ref.read_bool(g_prob)
        assert r_bit == g_bit, (
            f"[{label}] Python ref disagrees with golden at bit {i}: "
            f"prob={g_prob} ref={r_bit} golden={g_bit} — "
            f"golden.json or BoolDecoderRef is inconsistent"
        )

        # DUT
        dut_bit = await decode_one(dut, g_prob)

        if dut_bit != g_bit:
            await _teardown(dut, mem_task)
            raise AssertionError(
                f"[{label}] BIT MISMATCH at index {i} "
                f"({i+1}th bool read):\n"
                f"  prob={g_prob}\n"
                f"  DUT={dut_bit}  REF={g_bit}\n"
                f"  First {i} bits were correct.\n"
                f"  This is a RTL arithmetic or refill bug — the Python\n"
                f"  reference matches golden, so the formula is correct."
            )

        if (i + 1) % 500 == 0:
            cocotb.log.info(f"[{label}] {i+1}/{n} bits correct so far.")

    await _teardown(dut, mem_task)
    cocotb.log.info(f"[{label}] PASS — {n} bits all correct.")


# ---------------------------------------------------------------------------
# Load golden once at module level
# ---------------------------------------------------------------------------
def _load_golden():
    if not os.path.exists(_GOLDEN_PATH):
        raise FileNotFoundError(
            f"golden.json not found at {_GOLDEN_PATH}"
        )
    with open(_GOLDEN_PATH) as f:
        g = json.load(f)
    frame_data = bytes(g["frame_data"])
    part1_off  = g["frame"]["part1_off"]
    p0 = frame_data[:part1_off]
    p1 = frame_data[part1_off:]
    return g, p0, p1


# ---------------------------------------------------------------------------
# Test 1 — BD0 (partition 0): first 50 bits
#
# Start small — if the first 50 bits are wrong the arithmetic is broken.
# 50 bits covers the frame header fields up to roughly loop_filter_level.
# ---------------------------------------------------------------------------
@test.module("BoolDecoderTest")
@cocotb.test()
async def test_bd0_first50(dut):
    clk_task = cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    g, p0, _ = _load_golden()
    p0_bool = p0[10:]   # skip uncompressed frame header
    cocotb.log.info(
        f"BD0 total bits in golden: {len(g['bd0'])}  "
        f"p0_bool size: {len(p0_bool)}B  (p0={len(p0)}B minus 10B header)"
    )
    await run_partition(dut, p0_bool, g["bd0"], label="BD0_first50", max_bits=50)
    clk_task.cancel()


# ---------------------------------------------------------------------------
# Test 2 — BD0: full partition 0
#
# All frame header + all MB header bits.
# If test 1 passes but this fails, the refill logic has a corner case
# that only triggers after the first few bytes are consumed.
# ---------------------------------------------------------------------------
@test.module("BoolDecoderTest")
@cocotb.test()
async def test_bd0_full(dut):
    clk_task = cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    g, p0, _ = _load_golden()
    await run_partition(dut, p0[10:], g["bd0"], label="BD0_full")
    clk_task.cancel()


# ---------------------------------------------------------------------------
# Test 3 — BD1 (partition 1): first 50 bits
#
# BD1 is independent of BD0. Tests the token decoder path in isolation.
# ---------------------------------------------------------------------------
@test.module("BoolDecoderTest")
@cocotb.test()
async def test_bd1_first50(dut):
    """BD1: first 50 bits of partition 1 against golden."""
    clk_task = cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    g, _, p1 = _load_golden()
    cocotb.log.info(
        f"BD1 total bits in golden: {len(g['bd1'])}  "
        f"p1 size: {len(p1)}B"
    )
    await run_partition(dut, p1, g["bd1"], label="BD1_first50", max_bits=50)
    clk_task.cancel()


# ---------------------------------------------------------------------------
# Test 4 — BD1: full partition 1
# ---------------------------------------------------------------------------
@test.module("BoolDecoderTest")
@cocotb.test()
async def test_bd1_full(dut):
    """BD1: all bits of partition 1 against golden."""
    clk_task = cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    g, _, p1 = _load_golden()
    await run_partition(dut, p1, g["bd1"], label="BD1_full")
    clk_task.cancel()


# ---------------------------------------------------------------------------
# Test 5 — BD0 with slow memory (3-cycle latency)
#
# Verifies the DUT stalls correctly when the FIFO has backpressure.
# Uses only the first 100 bits to keep runtime short.
# ---------------------------------------------------------------------------
@test.module("BoolDecoderTest")
@cocotb.test()
async def test_bd0_slow_memory(dut):
    clk_task = cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    g, p0, _ = _load_golden()
    await run_partition(dut, p0[10:], g["bd0"], label="BD0_slow",
                        req_lat=3, data_lat=4, max_bits=100)
    clk_task.cancel()
