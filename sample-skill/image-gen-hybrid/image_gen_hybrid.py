#!/usr/bin/env python3
"""
image_gen_hybrid.py - Hybrid parallel image generation orchestrator

Accepts a list of prompts and automatically splits them equally between
cloud (nano-banana) and local (SD3.5). If the count is odd, cloud gets
the extra prompt.

Task A (cloud) and Task B (local) run in parallel.
Within each task, prompts are processed sequentially.

Usage:
  python image_gen_hybrid.py --prompts "prompt 1" "prompt 2" "prompt 3" "prompt 4"
  python image_gen_hybrid.py --prompts "hero prompt" "card 1" "card 2" --output-dir "C:\\path\\to\\output"
"""

import argparse
import math
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import os

# Ensure stdout/stderr handle non-ASCII characters on Windows
if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if sys.stderr.encoding and sys.stderr.encoding.lower() != "utf-8":
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# ── Hardcoded paths ────────────────────────────────────────────────────────────
DEFAULT_OUTPUT_DIR = r"C:\Users\HCKTest\.openclaw\media\hybrid-images"
SD35_SCRIPT        = (
    r"C:\Users\HCKTest\.openclaw\workspace\skills\image-gen-hybrid\SD3.5_Tool.py"
)
NANO_BANANA_SCRIPT = (
    r"C:\Users\HCKTest\.openclaw\workspace\skills\image-gen-hybrid\nano-banana.py"
)


value = os.getenv("GEMINI_API_KEY")
if not value:
    raise RuntimeError("GEMINI_API_KEY environment variable is not set")



def split_prompts(prompts: list[str]) -> tuple[list[str], list[str]]:
    """Split prompts equally between cloud and local.
    If odd count, cloud gets the extra prompt (first half rounds up).
    """
    total = len(prompts)
    cloud_count = math.ceil(total / 2)
    cloud_prompts = prompts[:cloud_count]
    local_prompts = prompts[cloud_count:]
    return cloud_prompts, local_prompts


# ── Task A — Cloud (nano-banana.py, sequential) ────────────────────────────────
def run_cloud_prompts(prompts: list[str], output_dir: str) -> dict:
    """Run each cloud prompt sequentially through nano-banana.py."""
    results = []
    for idx, prompt in enumerate(prompts, start=1):
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        output_filename = str(Path(output_dir) / f"gemini_cloud_{idx}_{timestamp}.png")

        print(f"[Task A] Cloud image {idx}/{len(prompts)}: {prompt[:60]}...")
        start = time.time()
        try:
            result = subprocess.run(
                [
                    sys.executable,
                    NANO_BANANA_SCRIPT,
                    "--prompt",   prompt,
                    "--filename", output_filename,
                    "--api-key",  os.getenv("GEMINI_API_KEY"),
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            elapsed = time.time() - start
            print(f"[Task A] Cloud image {idx} complete ({elapsed:.1f}s) → {output_filename}")
            results.append({
                "index": idx,
                "prompt": prompt,
                "status": "success",
                "output": output_filename,
                "elapsed": elapsed,
            })
        except subprocess.CalledProcessError as e:
            elapsed = time.time() - start
            msg = e.stderr.strip() or e.stdout.strip()
            print(f"[Task A] Cloud image {idx} FAILED ({elapsed:.1f}s): {msg}")
            results.append({
                "index": idx,
                "prompt": prompt,
                "status": "error",
                "output": msg,
                "elapsed": elapsed,
            })
        except Exception as e:
            elapsed = time.time() - start
            msg = str(e)
            print(f"[Task A] Cloud image {idx} ERROR ({elapsed:.1f}s): {msg}")
            results.append({
                "index": idx,
                "prompt": prompt,
                "status": "error",
                "output": msg,
                "elapsed": elapsed,
            })    

    return {"task": "A", "model": "nano-banana / gemini-3-pro-image-preview (cloud)", "results": results}


# ── Task B — Local (SD3.5_Tool.py, sequential) ────────────────────────────────
def run_local_prompts(prompts: list[str], output_dir: str) -> dict:
    """Run each local prompt sequentially through SD3.5_Tool.py.
    SD3.5_Tool.py saves to Output/sd35_npu_output_<timestamp>.png relative to cwd.
    It does not accept --output-dir; output path is printed to stdout.
    """
    results = []
    for idx, prompt in enumerate(prompts, start=1):
        print(f"[Task B] Local image {idx}/{len(prompts)}: {prompt[:60]}...")
        start = time.time()
        try:
            result = subprocess.run(
                [
                    sys.executable,
                    SD35_SCRIPT,
                    "--prompt", prompt,
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            elapsed = time.time() - start
            output = result.stdout.strip()
            print(f"[Task B] Local image {idx} complete ({elapsed:.1f}s)")
            results.append({
                "index": idx,
                "prompt": prompt,
                "status": "success",
                "output": output,
                "elapsed": elapsed,
            })
        except subprocess.CalledProcessError as e:
            elapsed = time.time() - start
            msg = e.stderr.strip() or e.stdout.strip()
            print(f"[Task B] Local image {idx} FAILED ({elapsed:.1f}s): {msg}")
            results.append({
                "index": idx,
                "prompt": prompt,
                "status": "error",
                "output": msg,
                "elapsed": elapsed,
            })
        except Exception as e:
            elapsed = time.time() - start
            msg = str(e)
            print(f"[Task B] Local image {idx} ERROR ({elapsed:.1f}s): {msg}")
            results.append({
                "index": idx,
                "prompt": prompt,
                "status": "error",
                "output": msg,
                "elapsed": elapsed,
            })    

    return {"task": "B", "model": "SD3.5 Medium (local)", "results": results}


# ── Main ───────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Hybrid parallel image generation — prompts split equally between cloud and local"
    )
    parser.add_argument(
        "--prompts", "-p",
        nargs="+",
        required=True,
        help="One or more image prompts. Split equally: first half -> cloud (nano-banana), second half -> local (SD3.5).",
    )
    parser.add_argument(
        "--output-dir", "-o",
        default=DEFAULT_OUTPUT_DIR,
        help=f"Output directory for generated images (default: {DEFAULT_OUTPUT_DIR})",
    )
    args = parser.parse_args()

    if not args.prompts:
        print("ERROR: At least one prompt is required.")
        sys.exit(1)

    cloud_prompts, local_prompts = split_prompts(args.prompts)
    output_dir = args.output_dir
    Path(output_dir).mkdir(parents=True, exist_ok=True)

    print("=" * 64)
    print("Image Generation — Hybrid Parallel Execution")
    print(f"  Total prompts : {len(args.prompts)}")
    print(f"  Cloud (A)     : {len(cloud_prompts)} prompt(s) -> nano-banana")
    for i, p in enumerate(cloud_prompts, 1):
        print(f"    {i}. {p[:70]}")
    print(f"  Local (B)     : {len(local_prompts)} prompt(s) -> SD3.5")
    for i, p in enumerate(local_prompts, 1):
        print(f"    {i}. {p[:70]}")
    print(f"  Output dir    : {output_dir}")
    print("=" * 64)

    overall_start = time.time()
    task_results = {}
    futures = []

    with ThreadPoolExecutor(max_workers=2) as executor:
        if cloud_prompts:
            futures.append(executor.submit(run_cloud_prompts, cloud_prompts, output_dir))
        if local_prompts:
            futures.append(executor.submit(run_local_prompts, local_prompts, output_dir))

        for future in as_completed(futures):
            r = future.result()
            task_results[r["task"]] = r

    overall_elapsed = time.time() - overall_start

    print("\n" + "=" * 64)
    print("✅ All image generation complete!")
    print(f"⏱️  Total wall-clock time: {overall_elapsed:.1f}s\n")

    for task_key in ("A", "B"):
        task = task_results.get(task_key)
        if not task:
            continue
        label = "Cloud (nano-banana)" if task_key == "A" else "Local (SD3.5)"
        for r in task.get("results", []):
            icon = "✅" if r["status"] == "success" else "❌"
            print(f"{icon} [{label}] Image {r['index']}: {r['status']}  ({r['elapsed']:.1f}s)")
            if r.get("output"):
                print(f"   {r['output']}")

    print("=" * 64)


if __name__ == "__main__":
    main()