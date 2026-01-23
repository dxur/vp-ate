import test
import logging
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge


@test.module("VpAteTest")
@cocotb.test()
async def test_vp_ate(dut):
    pass
