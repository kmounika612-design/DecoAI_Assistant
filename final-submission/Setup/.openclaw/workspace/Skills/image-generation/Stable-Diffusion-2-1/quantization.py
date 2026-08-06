"""Quantization helpers for the precompiled SD2.1 QNN ONNX package.

Unlike the SD3 ORT QNN export (whose wrapper .onnx files insert QuantizeLinear/
DequantizeLinear nodes so callers see plain float32), this package's
text_encoder.onnx / unet.onnx / vae.onnx declare their *outer* graph I/O as raw
uint16 (confirmed via onnx.load and a live sess.run() call). Callers must
quantize inputs and dequantize outputs manually using the affine scale/zero_point
pairs published in metadata.json, following the standard ONNX QuantizeLinear/
DequantizeLinear formula.
"""

import json
import os

import numpy as np

MODEL_DIR = (
    r"C:\Users\qc_de\Desktop\DecoAI Assistant\DecoAI_Assistant-pragnya\DecoAI_Assistant-pragnya\Stable-Diffusion-2-1\Model_Bins"
)

with open(os.path.join(MODEL_DIR, "metadata.json")) as f:
    _METADATA = json.load(f)


def _qparams(onnx_file, tensor_name, kind):
    q = _METADATA["model_files"][onnx_file][kind][tensor_name]["quantization_parameters"]
    return q["scale"], q["zero_point"]


def quantize(x, scale, zero_point, dtype=np.uint16):
    return np.clip(np.round(np.asarray(x, dtype=np.float64) / scale) + zero_point, 0, 65535).astype(dtype)


def dequantize(x, scale, zero_point):
    return (x.astype(np.float32) - zero_point) * np.float32(scale)


TEXT_EMBEDDING_SCALE, TEXT_EMBEDDING_ZP = _qparams("text_encoder.onnx", "text_embedding", "outputs")

UNET_LATENT_SCALE, UNET_LATENT_ZP = _qparams("unet.onnx", "latent", "inputs")
UNET_TIMESTEP_SCALE, UNET_TIMESTEP_ZP = _qparams("unet.onnx", "timestep", "inputs")
UNET_TEXT_EMB_SCALE, UNET_TEXT_EMB_ZP = _qparams("unet.onnx", "text_emb", "inputs")
UNET_OUTPUT_LATENT_SCALE, UNET_OUTPUT_LATENT_ZP = _qparams("unet.onnx", "output_latent", "outputs")

VAE_LATENT_SCALE, VAE_LATENT_ZP = _qparams("vae.onnx", "latent", "inputs")
VAE_IMAGE_SCALE, VAE_IMAGE_ZP = _qparams("vae.onnx", "image", "outputs")
