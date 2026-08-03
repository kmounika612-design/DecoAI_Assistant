"""DecoAI Cost Estimator — FastAPI service (Diagram 1).

Takes a decoration concept's needed items, checks the shared inventory DB, and
returns an itemized estimate plus the list of missing items to purchase.
Registered as an OpenClaw skill; also runnable standalone.
"""
import os

from fastapi import FastAPI
from pydantic import BaseModel

from .estimator import NeededItem, Estimate, estimate
from .model_context_lengths import ModelInfo, list_cirrascale_models

app = FastAPI(title="DecoAI Cost Estimator", version="0.1.0")


class ModelLookupRequest(BaseModel):
    base_url: str = "https://aisuite.cirrascale.com"
    api_key: str | None = None


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/estimate", response_model=Estimate)
def create_estimate(items: list[NeededItem]) -> Estimate:
    """Itemized cost estimate for a decoration concept's needed items."""
    return estimate(items)


@app.post("/model-context-lengths", response_model=list[ModelInfo])
def model_context_lengths(req: ModelLookupRequest) -> list[ModelInfo]:
    """List models on a Cirrascale AI Suite endpoint with their max context length."""
    api_key = req.api_key or os.environ["AISUITE_API_KEY"]
    return list_cirrascale_models(req.base_url, api_key)
