#!/usr/bin/env python3
"""
Test runner for cocotb-based RTL simulations.
Discovers test files, lists their contents, and runs them via make.
"""

import os
import sys
import importlib.util
import subprocess
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional

TEST_DIR = Path("test")
RTL_DIR = Path("rtl")
MAKEFILE = "cocotb.mk"


@dataclass
class TestFile:
    path: Path
    top: str
    tests: list[str] = field(default_factory=list)

    @property
    def module_name(self) -> str:
        """Dot-separated module path suitable for cocotb MODULE env var."""
        return str(self.path.with_suffix("")).replace(os.sep, ".")

    @property
    def stem(self) -> str:
        return self.path.stem


def discover_test_files(test_dir: Path = TEST_DIR) -> dict[str, TestFile]:
    """
    Scan test_dir for Python test files and extract cocotb test functions.
    Files starting with '_' are ignored.
    Returns a dict of { file_stem: TestFile }.
    """
    if not test_dir.exists():
        fatal(f"Test directory '{test_dir}' not found.")

    test_files: dict[str, TestFile] = {}

    for path in sorted(test_dir.glob("*.py")):
        if path.stem.startswith("_"):
            continue

        try:
            spec = importlib.util.spec_from_file_location(path.stem, path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        except Exception as e:
            warn(f"Could not import '{path}': {e}")
            continue

        tests: list[str] = []
        top: Optional[str] = None

        for name in dir(module):
            obj = getattr(module, name)
            if hasattr(obj, "_test_module"):
                tests.append(name)
                if top is None:
                    top = obj._test_module
                elif top != obj._test_module:
                    warn(
                        f"'{path}' has tests with different _test_module values — "
                        f"using first encountered: '{top}'"
                    )

        if not tests:
            continue

        if top is None:
            warn(f"'{path}' has no _test_module set — skipping.")
            continue

        test_files[path.stem] = TestFile(path=path, top=top, tests=tests)

    return test_files


def run_file(tf: TestFile, rtl_files: list[str]) -> None:
    """Run all tests in a TestFile by invoking make with the appropriate env."""
    env = os.environ.copy()
    env["TOPLEVEL"] = tf.top
    env["MODULE"] = tf.module_name
    env["EXTRA_RTL"] = " ".join(rtl_files)

    info(f"Running '{tf.path}'  top={tf.top}  ({len(tf.tests)} test(s))")
    result = subprocess.run(
        ["make", "-f", MAKEFILE],
        env=env,
        text=True,
    )
    if result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, "make")


def collect_rtl_files(rtl_dir: Path = RTL_DIR) -> list[str]:
    if not rtl_dir.exists():
        warn(f"RTL directory '{rtl_dir}' not found — EXTRA_RTL will be empty.")
        return []
    return [str(f) for f in sorted(rtl_dir.rglob("*.sv"))]


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

RESET = "\033[0m"
BOLD = "\033[1m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"


def _colored(color: str, msg: str) -> str:
    return f"{color}{msg}{RESET}" if sys.stdout.isatty() else msg


def info(msg: str) -> None:
    print(_colored(CYAN, f"  → {msg}"))


def ok(msg: str) -> None:
    print(_colored(GREEN, f"  ✓ {msg}"))


def warn(msg: str) -> None:
    print(_colored(YELLOW, f"  ⚠ {msg}"), file=sys.stderr)


def fatal(msg: str, code: int = 1) -> None:
    print(_colored(RED, f"  ✗ {msg}"), file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_list(test_files: dict[str, TestFile]) -> None:
    if not test_files:
        print("No test files found.")
        return

    print(f"\n{BOLD}Test files ({len(test_files)}){RESET}" if sys.stdout.isatty()
          else f"\nTest files ({len(test_files)})")

    for tf in test_files.values():
        print(f"\n  {BOLD}{tf.path}{RESET}  top={tf.top}" if sys.stdout.isatty()
              else f"\n  {tf.path}  top={tf.top}")
        for t in tf.tests:
            print(f"    - {t}")


def cmd_run(
    test_files: dict[str, TestFile],
    targets: list[str],
    rtl_files: list[str],
) -> None:
    """
    Run a subset of test files (matched by stem or path fragment),
    or all of them if targets is empty.
    """
    if targets:
        selected: dict[str, TestFile] = {}
        for target in targets:
            matches = {
                stem: tf for stem, tf in test_files.items()
                if target == stem or target in str(tf.path)
            }
            if not matches:
                warn(f"No test file matched '{target}'.")
            selected.update(matches)
        if not selected:
            fatal("No test files matched the given targets.")
    else:
        selected = test_files

    passed: list[str] = []
    failed: list[str] = []

    for tf in selected.values():
        try:
            run_file(tf, rtl_files)
            ok(f"{tf.path}")
            passed.append(tf.stem)
        except subprocess.CalledProcessError:
            print(_colored(RED, f"  ✗ {tf.path} — FAILED"), file=sys.stderr)
            failed.append(tf.stem)

    _print_summary(passed, failed)

    if failed:
        sys.exit(1)


def _print_summary(passed: list[str], failed: list[str]) -> None:
    total = len(passed) + len(failed)
    print()
    if failed:
        print(_colored(RED, f"  {len(failed)}/{total} file(s) FAILED: {', '.join(failed)}"))
    else:
        print(_colored(GREEN, f"  {total}/{total} file(s) passed."))


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

USAGE = """\
Usage:
  {prog} [list]
  {prog} run [<file> ...]

Commands:
  help              Print this message and exit.
  list              List all discovered test files and their tests.
  run [<file> ...]  Run specified test files (by stem or path fragment).
                    Runs all files if none are specified.

Examples:
  {prog} list
  {prog} run
  {prog} run test_uart test_spi
"""


def main() -> None:
    args = sys.argv[1:]
    cmd = args[0] if args else "run"

    if cmd in ("help"):
        print(USAGE.format(prog=Path(sys.argv[0]).name))
        sys.exit(0)

    test_files = discover_test_files()

    if not test_files:
        fatal("No test files discovered.")

    if cmd == "list":
        cmd_list(test_files)

    elif cmd == "run":
        rtl_files = collect_rtl_files()
        cmd_run(test_files, targets=args[1:], rtl_files=rtl_files)

    else:
        print(USAGE.format(prog=Path(sys.argv[0]).name), file=sys.stderr)
        fatal(f"Unknown command: '{cmd}'")


if __name__ == "__main__":
    main()
