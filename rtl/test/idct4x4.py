import logging
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge


def idct4x4(block):
    out = [row[:] for row in block]

    COSPI8SQRT2MINUS1 = 20091
    SINPI8SQRT2 = 35468

    for col in range(4):
        ip0 = out[0][col]
        ip4 = out[1][col]
        ip8 = out[2][col]
        ip12 = out[3][col]

        a1 = ip0 + ip8
        b1 = ip0 - ip8

        t1 = (ip4 * SINPI8SQRT2) >> 16
        t2 = ip12 + ((ip12 * COSPI8SQRT2MINUS1) >> 16)
        c1 = t1 - t2

        t1 = ip4 + ((ip4 * COSPI8SQRT2MINUS1) >> 16)
        t2 = (ip12 * SINPI8SQRT2) >> 16
        d1 = t1 + t2

        out[0][col] = a1 + d1
        out[1][col] = b1 + c1
        out[2][col] = b1 - c1
        out[3][col] = a1 - d1

    for row in range(4):
        ip0 = out[row][0]
        ip1 = out[row][1]
        ip2 = out[row][2]
        ip3 = out[row][3]

        a1 = ip0 + ip2
        b1 = ip0 - ip2

        t1 = (ip1 * SINPI8SQRT2) >> 16
        t2 = ip3 + ((ip3 * COSPI8SQRT2MINUS1) >> 16)
        c1 = t1 - t2

        t1 = ip1 + ((ip1 * COSPI8SQRT2MINUS1) >> 16)
        t2 = (ip3 * SINPI8SQRT2) >> 16
        d1 = t1 + t2

        out[row][0] = (a1 + d1 + 4) >> 3
        out[row][1] = (b1 + c1 + 4) >> 3
        out[row][2] = (b1 - c1 + 4) >> 3
        out[row][3] = (a1 - d1 + 4) >> 3

    return out


def iwht4x4(block):
    out = [row[:] for row in block]

    for col in range(4):
        a1 = out[0][col] + out[3][col]
        b1 = out[1][col] + out[2][col]
        c1 = out[1][col] - out[2][col]
        d1 = out[0][col] - out[3][col]

        out[0][col] = a1 + b1
        out[1][col] = c1 + d1
        out[2][col] = a1 - b1
        out[3][col] = d1 - c1

    for row in range(4):
        a1 = out[row][0] + out[row][3]
        b1 = out[row][1] + out[row][2]
        c1 = out[row][1] - out[row][2]
        d1 = out[row][0] - out[row][3]

        a2 = a1 + b1
        b2 = c1 + d1
        c2 = a1 - b1
        d2 = d1 - c1

        out[row][0] = (a2 + 3) >> 3
        out[row][1] = (b2 + 3) >> 3
        out[row][2] = (c2 + 3) >> 3
        out[row][3] = (d2 + 3) >> 3

    return out


async def drive_and_test(dut, sample, transform):
    logging.info(f"Drive and test, sample={sample}")
    for i in range(4):
        for j in range(4):
            dut.coeff[i][j].value = sample[i][j]

    dut.coeff_valid.value = True
    await RisingEdge(dut.clk)
    while dut.coeff_ready.value != True:
        await RisingEdge(dut.clk)
    dut.coeff_valid.value = False

    await RisingEdge(dut.block_valid)

    dut_output = [
        [dut.block[i][j].value.to_signed() for j in range(4)] for i in range(4)
    ]
    dut.block_ready.value = True

    await RisingEdge(dut.clk)
    dut.block_ready.value = True

    expected = transform(sample)

    assert dut_output == expected, (
        f"DUT output does not match expected result.\n"
        f"Expected: {expected}\n"
        f"Got:      {dut_output}"
    )


@cocotb.test()
async def test_idct4x4(dut):
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.rst.value = 0
    await Timer(20, "ns")
    dut.rst.value = 1
    await RisingEdge(dut.clk)

    dut.dct_or_wht.value = 0
    for _ in range(100):
        sample = [[random.randint(-128, 127) for _ in range(4)] for _ in range(4)]
        await drive_and_test(dut, sample, idct4x4)

    dut.dct_or_wht.value = 1
    for _ in range(100):
        sample = [[random.randint(-128, 127) for _ in range(4)] for _ in range(4)]
        await drive_and_test(dut, sample, iwht4x4)
