#!/usr/bin/env python3
"""Cirrascale Image Generation CLI — calls the Cirrascale AI Suite images API.

Sends a text prompt to Cirrascale's hosted image models (default: sdxl-turbo)
and saves the returned image(s) to disk. Cloud API call — no local model/NPU
involved. Requires CIRRASCALE_API_KEY in the environment (or .env at the repo
root).

Always calls the API with stream=true and reads the resulting SSE event(s) —
Cirrascale's non-streaming mode (stream=false) does not return in practical
time (confirmed to hang 90s+ where streaming completes in ~15s), so this
script does not offer a non-streaming path.

Usage:
    decoai-generate-image "<prompt>" [options]

Exit codes: 0 = success, 1 = bad input / missing config, 2 = API error.
"""
import argparse
import base64
import json
import os
import sys
import time
from pathlib import Path
from typing import List, Optional, Tuple

_SVC = Path(__file__).resolve().parent          # image-generation/
sys.path.insert(0, str(_SVC.parent))            # repo root (shared .env)

from dotenv import load_dotenv                                         # noqa: E402
load_dotenv(_SVC.parent / ".env")

import httpx                                                            # noqa: E402

API_URL = "https://aisuite.cirrascale.com/apis/v2/images/generations"
DEFAULT_MODEL = "stabilityai/sdxl-turbo"


def _extract_images(payload: dict) -> List[Tuple[str, str]]:
    """Pull (kind, value) pairs out of a Cirrascale response payload.

    kind is "b64_json" or "url" depending on what the API returned per item.
    """
    images = []
    for item in payload.get("data", []):
        if "b64_json" in item:
            images.append(("b64_json", item["b64_json"]))
        elif "url" in item:
            images.append(("url", item["url"]))
    return images


def _save_b64_image(b64_data: str, out_dir: Path, prefix: str, index: int) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{prefix}_{int(time.time())}_{index}.png"
    path.write_bytes(base64.b64decode(b64_data))
    return path


def _call_streaming(client: httpx.Client, headers: dict, body: dict, timeout: float) -> Optional[dict]:
    """POST with stream=True and return the last complete SSE JSON event.

    Observed behavior: Cirrascale sends one `data: {...}` event carrying the
    complete, fully-decoded image(s) and then closes the connection (no
    `[DONE]` sentinel seen in practice) — but a `[DONE]` line is handled too,
    in case a model/config streams multiple partial updates.
    """
    last_payload = None
    with client.stream("POST", API_URL, headers=headers, json=body, timeout=timeout) as resp:
        resp.raise_for_status()
        for line in resp.iter_lines():
            if not line or not line.startswith("data:"):
                continue
            data = line[len("data:"):].strip()
            if data == "[DONE]":
                break
            try:
                last_payload = json.loads(data)
            except json.JSONDecodeError:
                continue
    return last_payload


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="decoai-generate-image",
        description="Generate image(s) via the Cirrascale AI Suite images API.",
    )
    parser.add_argument("prompt", help="text prompt describing the image")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--size", default=None)
    parser.add_argument("--n", type=int, default=1)
    parser.add_argument("--steps", type=int, default=50, help="num_inference_steps")
    parser.add_argument("--guidance-scale", type=float, default=7.5)
    parser.add_argument("--seed", type=int, default=4)
    parser.add_argument("--seed-increment", type=int, default=None)
    parser.add_argument("--response-format", default="b64_json", choices=["b64_json", "url"])
    parser.add_argument("--output-dir", default="Skills/image-generation/output",
                        help="workspace-relative by default, so saved_paths can be embedded "
                             "directly as markdown image links")
    parser.add_argument("--prefix", default="cirrascale")
    parser.add_argument("--timeout", type=float, default=90,
                        help="request timeout in seconds (cold-start GPU calls can take ~15-60s)")
    parser.add_argument("--json", action="store_true", help="emit a JSON result summary")
    args = parser.parse_args()

    api_key = os.environ.get("CIRRASCALE_API_KEY")
    if not api_key:
        print("ERROR: CIRRASCALE_API_KEY is not set (add it to .env)", file=sys.stderr)
        return 1

    body = {
        "model": args.model,
        "prompt": args.prompt,
        "stream": True,
        "guidance_scale": args.guidance_scale,
        "size": args.size,
        "n": args.n,
        "num_inference_steps": args.steps,
        "response_format": args.response_format,
    }
    if args.seed is not None:
        body["seed"] = args.seed
    if args.seed_increment is not None:
        body["seed_increment"] = args.seed_increment

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }
    verify = os.environ.get("DECOAI_INSECURE_SSL", "false").lower() != "true"

    try:
        with httpx.Client(verify=verify) as client:
            payload = _call_streaming(client, headers, body, args.timeout)
    except httpx.HTTPStatusError as e:
        print(f"ERROR: Cirrascale API returned {e.response.status_code}: {e.response.text}",
              file=sys.stderr)
        return 2
    except httpx.HTTPError as e:
        print(f"ERROR: request to Cirrascale API failed: {e}", file=sys.stderr)
        return 2

    if not payload:
        print("ERROR: no response payload from Cirrascale API", file=sys.stderr)
        return 2

    images = _extract_images(payload)
    if not images:
        print(f"ERROR: no image data in response: {payload}", file=sys.stderr)
        return 2

    out_dir = Path(args.output_dir)
    saved_paths, urls = [], []
    for i, (kind, value) in enumerate(images):
        if kind == "b64_json":
            saved_paths.append(str(_save_b64_image(value, out_dir, args.prefix, i)))
        else:
            urls.append(value)

    if args.json:
        print(json.dumps({"saved_paths": saved_paths, "urls": urls}))
    else:
        for p in saved_paths:
            print(f"Saved: {p}")
        for u in urls:
            print(f"URL: {u}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
