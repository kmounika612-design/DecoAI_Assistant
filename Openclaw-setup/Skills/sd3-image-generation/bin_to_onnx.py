#!/usr/bin/env python3
"""
bin_to_onnx.py - Convert QNN serialized context binaries into ORT-QNN wrapper ONNX models.

For each *.serialized.bin in MODEL_BINS_DIR:
  1. Run qnn-context-binary-utility.exe to extract the context binary's graph I/O
     metadata into a JSON file.
  2. Run gen_qnn_ctx_onnx_model.py against the bin + JSON to produce a
     *_qnn_ctx_fp32_io.onnx wrapper, written to OUTPUT_DIR (drop that folder's
     contents into Model_Bins/ for session_server.py).

Usage:
    python bin_to_onnx.py
"""
import glob
import os
import platform
import subprocess
import sys

# ─── Config ───────────────────────────────────────────────────────────────────
QAIRT_SDK_ROOT = r"C:\Users\HCKTest\Downloads\qairt-sdk-v2.43.0.260128150333_193827\qairt\2.43.0.260128"
MODEL_BINS_DIR = r"C:\mounika\DecoAI\sd3_ort_qnn\serialized_binaries\serialized_binaries"

HERE = os.path.dirname(os.path.abspath(__file__))
JSON_DIR = os.path.join(HERE, "qnn_ctx_json")     # extracted context-binary metadata
OUTPUT_DIR = os.path.join(HERE, "Model_Bins")     # final *_qnn_ctx_fp32_io.onnx files
GEN_SCRIPT = os.path.join(HERE, "gen_qnn_ctx_onnx_model.py")


def _sdk_arch_dir() -> str:
    machine = platform.machine().lower()
    if machine in ("arm64", "aarch64"):
        return "aarch64-windows-msvc"
    return "x86_64-windows-msvc"


def _setup_qairt_env() -> str:
    """Point PATH/PYTHONPATH at the QAIRT SDK's arch-specific bin/lib dirs.

    Mirrors what bin/envsetup.ps1 does, without spawning PowerShell.
    Returns the path to qnn-context-binary-utility.exe.
    """
    arch_dir = _sdk_arch_dir()
    bin_dir = os.path.join(QAIRT_SDK_ROOT, "bin", arch_dir)
    lib_dir = os.path.join(QAIRT_SDK_ROOT, "lib", arch_dir)
    python_lib = os.path.join(QAIRT_SDK_ROOT, "lib", "python")

    if not os.path.isdir(bin_dir):
        raise RuntimeError(f"QAIRT SDK bin dir not found: {bin_dir}")

    os.environ["QAIRT_SDK_ROOT"] = QAIRT_SDK_ROOT
    os.environ["QNN_SDK_ROOT"] = QAIRT_SDK_ROOT
    os.environ["PATH"] = bin_dir + os.pathsep + lib_dir + os.pathsep + os.environ.get("PATH", "")
    os.environ["PYTHONPATH"] = python_lib + os.pathsep + os.environ.get("PYTHONPATH", "")

    utility = os.path.join(bin_dir, "qnn-context-binary-utility.exe")
    if not os.path.isfile(utility):
        raise RuntimeError(f"qnn-context-binary-utility.exe not found: {utility}")
    return utility


def _extract_metadata(utility: str, bin_file: str, json_file: str) -> None:
    """Run qnn-context-binary-utility to dump the context binary's graph I/O metadata."""
    print(f"[extract] {os.path.basename(bin_file)} -> {os.path.basename(json_file)}")
    subprocess.run(
        [utility, "--context_binary", bin_file, "--json_file", json_file],
        check=True,
    )


def _convert_to_onnx(bin_file: str, json_file: str, output_dir: str) -> None:
    """Run gen_qnn_ctx_onnx_model.py; it writes the wrapper *.onnx into the cwd."""
    print(f"[convert] {os.path.basename(json_file)} -> onnx (in {output_dir})")
    subprocess.run(
        [sys.executable, GEN_SCRIPT, "-b", bin_file, "-q", json_file],
        cwd=output_dir,
        check=True,
    )


def main() -> int:
    bin_files = sorted(glob.glob(os.path.join(MODEL_BINS_DIR, "*.serialized.bin")))
    if not bin_files:
        print(f"ERROR: no *.serialized.bin files found in {MODEL_BINS_DIR}", file=sys.stderr)
        return 1

    os.makedirs(JSON_DIR, exist_ok=True)
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    utility = _setup_qairt_env()

    for bin_file in bin_files:
        name = os.path.basename(bin_file).replace(".serialized.bin", "")
        json_file = os.path.join(JSON_DIR, f"{name}.json")
        _extract_metadata(utility, bin_file, json_file)
        _convert_to_onnx(bin_file, json_file, OUTPUT_DIR)

    print(f"\nDone. Wrapper ONNX models written to: {OUTPUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
