"""List models available on an OpenAI-compatible or Cirrascale AI Suite endpoint,
paired with their max context length.

Context length isn't a field either API format returns — OpenAI's /v1/models
gives only id/object/created/owned_by, and Cirrascale's /apis/v2/models gives
just names grouped by type. So it's resolved from a hardcoded table keyed by
model name, filled in from each model's published model card.
"""
import os
from typing import Optional

import httpx
from pydantic import BaseModel

# Context length (tokens) per model, from published model cards.
# Extend this as new models are added to either endpoint.
_CONTEXT_LENGTHS = {
    "Llama-3.1-8B": 128_000,
    "gpt-4o": 128_000,
    "gpt-4-turbo": 128_000,
    "gpt-3.5-turbo": 16_385,
    "claude-opus-5": 1_000_000,
    "claude-sonnet-5": 1_000_000,
}


class ModelInfo(BaseModel):
    id: str
    type: Optional[str] = None
    context_length: Optional[int] = None


def list_cirrascale_models(base_url: str, api_key: str) -> list[ModelInfo]:
    """Fetch the {type: [names]} map from Cirrascale AI Suite and flatten it."""
    resp = httpx.get(f"{base_url.rstrip('/')}/apis/v2/models",
                      headers={"Authorization": f"Bearer {api_key}"}, timeout=30)
    resp.raise_for_status()
    by_type = resp.json()
    return [
        ModelInfo(id=name, type=model_type, context_length=_CONTEXT_LENGTHS.get(name))
        for model_type, names in by_type.items()
        for name in names
    ]


def list_openai_models(base_url: str, api_key: str) -> list[ModelInfo]:
    """Fetch /v1/models from any OpenAI-compatible endpoint."""
    resp = httpx.get(f"{base_url.rstrip('/')}/v1/models",
                      headers={"Authorization": f"Bearer {api_key}"}, timeout=30)
    resp.raise_for_status()
    return [
        ModelInfo(id=m["id"], context_length=_CONTEXT_LENGTHS.get(m["id"]))
        for m in resp.json().get("data", [])
    ]


if __name__ == "__main__":
    base_url = os.environ.get("AISUITE_URL", "https://aisuite.cirrascale.com")
    api_key = os.environ["AISUITE_API_KEY"]
    for model in list_cirrascale_models(base_url, api_key):
        ctx = model.context_length or "unknown"
        print(f"{model.id:30} type={model.type:12} context_length={ctx}")
