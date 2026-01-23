#!/usr/bin/env python3

import os
import subprocess
import importlib.util
from pathlib import Path
import sys

TEST_DIR = Path("test")
RTL_DIR = Path("rtl")

def discover_tests():
    tests = []
    for f in TEST_DIR.glob("*.py"):
        if f.stem.startswith("_"):
            continue
        spec = importlib.util.spec_from_file_location(f.stem, f)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for name in dir(module):
            obj = getattr(module, name)
            if hasattr(obj, "_test_module"):
                tests.append({
                    "name": name,
                    "top": obj._test_module,
                    "file": str(f)
                })
    return tests

def run_test(test):
    env = os.environ.copy()
    env["TOPLEVEL"] = test["top"]
    env["MODULE"] = test["file"].replace(".py", "").replace("/", ".")
    env["EXTRA_RTL"] = " ".join(str(f) for f in RTL_DIR.rglob("*.sv"))
    print(f"Running {test['name']} on top {test['top']}")
    subprocess.run(["make", "-f", "cocotb.mk"], env=env, check=True)

def list_tests(tests):
    print(f"Available tests: {len(tests)}")
    for t in tests:
        print(f"{t['name']} -> top={t['top']}")

if __name__ == "__main__":
    tests = discover_tests()
    tests_to_run = []
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == "list":
            list_tests(tests)
        elif cmd == "run":
            selected = [t for t in tests if t["name"] in sys.argv[2:]]
            if not selected:
                print(f"No test found matching {sys.argv[2:]}")
                sys.exit(1)
            tests_to_run = selected
        else:
            print(f"Unknown command {cmd}")
            sys.exit(1)
    else:
        tests_to_run = tests
    
    for test in tests_to_run:
        try:
            run_test(test)
        except subprocess.CalledProcessError as e:
            print(f"Test {test['name']} failed with error: {e}")
            sys.exit(1)
    print("All tests passed successfully.")
