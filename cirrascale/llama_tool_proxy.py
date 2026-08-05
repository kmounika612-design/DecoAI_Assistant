#!/usr/bin/env python3
"""
llama_tool_proxy.py
====================
Lightweight local proxy that fixes Llama 3.x plain-text tool calls into
proper OpenAI tool_calls SSE format.

Sits between your test script and a Cirrascale (or any vLLM) endpoint that
was NOT started with --tool-call-parser llama3_json.

What it does:
  1. Receives OpenAI /v1/chat/completions requests from your script
  2. Forwards them upstream (to Cirrascale) with streaming
  3. Collects the full response
  4. If the model emitted tool calls as plain text JSON (Llama native format),
     converts them into proper OpenAI tool_calls delta SSE
  5. Streams back a fully OpenAI-compatible response

Install:
  pip install fastapi uvicorn httpx

Start the proxy:
  python llama_tool_proxy.py \
    --upstream https://aisuite-indonesia.cirrascale.com/apis/v2 \
    --api-key b433eb73-9405-4481-a25d-803e1b052421

Then run your test script against localhost instead of Cirrascale:
  python "test_cloud_prompt 1.py" --direct \
    --base-url http://localhost:8100/v1 \
    --model Llama-3.3-70B
"""

import argparse
import json
import re
import uuid
from typing import AsyncIterator

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse

app = FastAPI()

# Set at startup via CLI args
UPSTREAM_BASE = ""
UPSTREAM_API_KEY = ""

# ── Llama special token stripper ──────────────────────────────────────────────

_LLAMA_TOKEN_RE = re.compile(
    r"<\|(?:eom_id|eot_id|start_header_id|end_header_id|python_tag|"
    r"fim_prefix|fim_middle|fim_suffix)\|>"
    r"(?:assistant|user|system|tool)?"
)

def _strip_llama_tokens(text: str) -> str:
    return _LLAMA_TOKEN_RE.sub("", text).strip()


# ── Plain-text tool call parser ───────────────────────────────────────────────

def _parse_text_tool_calls(text: str) -> list:
    """
    Extract tool calls from plain-text Llama output.

    Handles two formats:
      Format A (Llama native):
        {"type": "function", "name": "read", "parameters": {...}}
      Format B (OpenAI-style in text):
        {"name": "read", "arguments": {...}}

    Returns list of {"id", "name", "arguments_str"} or [] if none found.
    """
    text = _strip_llama_tokens(text)
    results = []
    depth = 0
    start = None

    for i, ch in enumerate(text):
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start is not None:
                chunk = text[start : i + 1]
                try:
                    obj = json.loads(chunk)
                except json.JSONDecodeError:
                    start = None
                    continue

                if obj.get("type") == "function" and "name" in obj:
                    # Format A
                    params = obj.get("parameters", obj.get("arguments", {}))
                    results.append({
                        "id": f"call_{uuid.uuid4().hex[:8]}",
                        "name": obj["name"],
                        "arguments_str": json.dumps(params, ensure_ascii=False),
                    })
                elif "name" in obj and "arguments" in obj and "type" not in obj:
                    # Format B
                    args = obj["arguments"]
                    results.append({
                        "id": f"call_{uuid.uuid4().hex[:8]}",
                        "name": obj["name"],
                        "arguments_str": (
                            json.dumps(args, ensure_ascii=False)
                            if isinstance(args, dict)
                            else str(args)
                        ),
                    })
                start = None

    return results


# ── SSE helpers ───────────────────────────────────────────────────────────────

def _sse(data: dict) -> str:
    return f"data: {json.dumps(data)}\n\n"


def _tool_calls_to_sse(tool_calls: list, model: str, cid: str) -> list[str]:
    """Emit one delta chunk per tool call, then a finish_reason=tool_calls chunk."""
    base = {"id": cid, "object": "chat.completion.chunk", "model": model}
    chunks = []

    for i, tc in enumerate(tool_calls):
        chunk = dict(base)
        chunk["choices"] = [{
            "index": 0,
            "delta": {
                "tool_calls": [{
                    "index": i,
                    "id": tc["id"],
                    "type": "function",
                    "function": {
                        "name": tc["name"],
                        "arguments": tc["arguments_str"],
                    },
                }]
            },
            "finish_reason": None,
        }]
        chunks.append(_sse(chunk))

    finish = dict(base)
    finish["choices"] = [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]
    chunks.append(_sse(finish))
    chunks.append("data: [DONE]\n\n")
    return chunks


# ── Upstream stream collector ─────────────────────────────────────────────────

async def _collect_upstream(response: httpx.Response):
    """
    Drain the upstream SSE stream.
    Returns (native_tool_calls, full_text, model, completion_id).
    native_tool_calls: populated when the upstream already returns proper tool_calls deltas.
    full_text: populated when the upstream returns plain-text content.
    """
    native_tcs: dict = {}
    committed_tcs: list = []
    full_text = ""
    model = "unknown"
    cid = f"chatcmpl-{uuid.uuid4().hex[:12]}"

    async for line in response.aiter_lines():
        if not line:
            continue
        raw = line[6:] if line.startswith("data: ") else line
        if raw == "[DONE]":
            break
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            continue

        if obj.get("model"):
            model = obj["model"]
        if obj.get("id"):
            cid = obj["id"]

        choices = obj.get("choices", [])
        if not choices:
            continue

        delta = choices[0].get("delta", {})
        finish_reason = choices[0].get("finish_reason")

        for tc in delta.get("tool_calls", []):
            idx = tc.get("index", 0)
            if idx not in native_tcs:
                native_tcs[idx] = {"id": "", "name": "", "arguments_str": ""}
            fn = tc.get("function", {})
            if tc.get("id"):
                native_tcs[idx]["id"] = tc["id"]
            if fn.get("name"):
                native_tcs[idx]["name"] = fn["name"]
            if fn.get("arguments"):
                native_tcs[idx]["arguments_str"] += fn["arguments"]

        if finish_reason == "tool_calls" and native_tcs:
            for idx in sorted(native_tcs):
                committed_tcs.append(native_tcs[idx])
            native_tcs = {}

        content = delta.get("content", "")
        if content:
            full_text += content

    # flush any remaining buffered tool calls
    for idx in sorted(native_tcs):
        committed_tcs.append(native_tcs[idx])

    return committed_tcs, full_text, model, cid


# ── Shared upstream caller (always streams internally to fix tool calls) ───────

async def _call_upstream(body: dict):
    """
    Always fetches upstream with stream=True so we can intercept and fix
    plain-text tool calls. Returns (native_tcs, full_text, model, cid).
    """
    upstream_url = f"{UPSTREAM_BASE.rstrip('/')}/chat/completions"
    headers = {"Content-Type": "application/json"}
    if UPSTREAM_API_KEY:
        headers["Authorization"] = f"Bearer {UPSTREAM_API_KEY}"

    upstream_body = dict(body)
    upstream_body["stream"] = True  # always stream upstream so we can intercept

    async with httpx.AsyncClient(timeout=httpx.Timeout(30, read=120), verify=False) as client:
        async with client.stream("POST", upstream_url, headers=headers, json=upstream_body) as resp:
            if resp.status_code != 200:
                raw = await resp.aread()
                raise RuntimeError(f"Upstream HTTP {resp.status_code}: {raw.decode()[:300]}")
            return await _collect_upstream(resp)


# ── Core proxy stream generator ───────────────────────────────────────────────

async def _proxy_stream(body: dict) -> AsyncIterator[str]:
    try:
        native_tcs, full_text, model, cid = await _call_upstream(body)
    except RuntimeError as e:
        yield _sse({"error": {"message": str(e)}})
        return

    # Case 1: upstream already returned proper structured tool_calls
    if native_tcs:
        for chunk in _tool_calls_to_sse(native_tcs, model, cid):
            yield chunk
        return

    if full_text:
        # Case 2: plain-text tool calls — parse and re-emit as proper SSE
        parsed_tcs = _parse_text_tool_calls(full_text)
        if parsed_tcs:
            for chunk in _tool_calls_to_sse(parsed_tcs, model, cid):
                yield chunk
            return

        # Case 3: plain text reply — stream it back
        base = {"id": cid, "object": "chat.completion.chunk", "model": model}
        text_chunk = dict(base)
        text_chunk["choices"] = [{
            "index": 0,
            "delta": {"role": "assistant", "content": full_text},
            "finish_reason": None,
        }]
        yield _sse(text_chunk)
        stop_chunk = dict(base)
        stop_chunk["choices"] = [{"index": 0, "delta": {}, "finish_reason": "stop"}]
        yield _sse(stop_chunk)
        yield "data: [DONE]\n\n"


def _tcs_to_openai_message(tcs: list) -> list:
    """Convert internal tool call dicts to OpenAI message.tool_calls format."""
    return [
        {
            "id": tc["id"],
            "type": "function",
            "function": {"name": tc["name"], "arguments": tc["arguments_str"]},
        }
        for tc in tcs
    ]


# ── Core proxy non-stream handler ─────────────────────────────────────────────

async def _proxy_json(body: dict) -> dict:
    try:
        native_tcs, full_text, model, cid = await _call_upstream(body)
    except RuntimeError as e:
        return {"error": {"message": str(e)}}

    # Case 1: proper structured tool_calls from upstream
    if native_tcs:
        return {
            "id": cid,
            "object": "chat.completion",
            "model": model,
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": _tcs_to_openai_message(native_tcs),
                },
                "finish_reason": "tool_calls",
            }],
        }

    if full_text:
        # Case 2: plain-text tool calls — parse and return as JSON
        parsed_tcs = _parse_text_tool_calls(full_text)
        if parsed_tcs:
            return {
                "id": cid,
                "object": "chat.completion",
                "model": model,
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": None,
                        "tool_calls": _tcs_to_openai_message(parsed_tcs),
                    },
                    "finish_reason": "tool_calls",
                }],
            }

        # Case 3: plain text reply
        return {
            "id": cid,
            "object": "chat.completion",
            "model": model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": full_text},
                "finish_reason": "stop",
            }],
        }

    return {"error": {"message": "Empty response from upstream"}}


# ── FastAPI routes ────────────────────────────────────────────────────────────

from fastapi.responses import JSONResponse

@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    wants_stream = body.get("stream", False)

    if wants_stream:
        return StreamingResponse(
            _proxy_stream(body),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )
    else:
        result = await _proxy_json(body)
        return JSONResponse(content=result)


@app.get("/v1/models")
async def list_models():
    """Pass-through the upstream models list."""
    url = f"{UPSTREAM_BASE.rstrip('/')}/models"
    headers = {}
    if UPSTREAM_API_KEY:
        headers["Authorization"] = f"Bearer {UPSTREAM_API_KEY}"
    async with httpx.AsyncClient(timeout=10, verify=False) as client:
        try:
            r = await client.get(url, headers=headers)
            return r.json()
        except Exception:
            return {"object": "list", "data": []}


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    global UPSTREAM_BASE, UPSTREAM_API_KEY

    parser = argparse.ArgumentParser(
        description="Llama tool-call fix proxy — converts plain-text tool calls to OpenAI format",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--upstream", required=True,
        help="Upstream base URL, e.g. https://aisuite-indonesia.cirrascale.com/apis/v2")
    parser.add_argument("--api-key", default="",
        help="Upstream API key")
    parser.add_argument("--port", type=int, default=8100,
        help="Local port to listen on (default: 8100)")
    args = parser.parse_args()

    UPSTREAM_BASE = args.upstream
    UPSTREAM_API_KEY = args.api_key

    print("Llama tool-call fix proxy")
    print(f"  Upstream  : {UPSTREAM_BASE}")
    print(f"  Listening : http://localhost:{args.port}/v1")
    print()
    print("Run your test script with:")
    print(f'  python "test_cloud_prompt 1.py" --direct \\')
    print(f'    --base-url http://localhost:{args.port}/v1 \\')
    print(f'    --model Llama-3.3-70B')
    print()

    uvicorn.run(app, host="0.0.0.0", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
