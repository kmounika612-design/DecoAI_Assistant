import argparse
import sys
import shutil
import os
import numpy as np
import torch
from diffusers import FlowMatchEulerDiscreteScheduler
from PIL import Image
import subprocess
import json
from datetime import datetime
from multiprocessing.managers import BaseManager
from transformers import CLIPTokenizer

# ─── Global Config ────────────────────────────────────────────────────────────
model_inference_time = {}
tmp_dirpath           = os.path.abspath('tmp')
cwd                   = os.getcwd()
context_binaries_path = os.path.join(cwd, "Model_Bins")
QNN_binaries_path     = os.path.join(cwd, "QNN_binaries")

# Calibration values from serialized_binaries/model_configs/diffuser.json
# (num-inference-steps / guidance-scale for this exported QNN graph).
user_step            = 28
tokenizer_max_length = 77
height, width        = 512, 512
user_seed            = np.int64(3)
user_text_guidance   = 7.0

# ─── Config generated ONCE per graph name ─────────────────────────────────────
_config_generated_for = None


def generate_config(graph):
    global _config_generated_for
    if _config_generated_for == graph:
        return
    os.makedirs(tmp_dirpath, exist_ok=True)
    htp_backend_extensions_data = {
        "backend_extensions": {
            "shared_library_path": "QnnHtpNetRunExtensions.dll",
            "config_file_path": os.path.join(tmp_dirpath, "htp_config.json")
        }
    }
    htp_backend_config_data = {
        "graphs": [{"graph_names": [graph], "vtcm_mb": 8, "O": 3.0, "hvx_threads": 8}],
        "devices": [{"soc_id": 88, "dsp_arch": "v81",
                     "cores": [{"rpc_control_latency": 100, "perf_profile": "burst"}]}],
        "context": [{"extended_udma": True}]
    }
    with open(os.path.join(tmp_dirpath, "htp_backend_extensions.json"), 'w') as f:
        json.dump(htp_backend_extensions_data, f, indent=4)
    with open(os.path.join(tmp_dirpath, "htp_config.json"), 'w') as f:
        json.dump(htp_backend_config_data, f, indent=4)
    _config_generated_for = graph


def run_command(command, output_log=None):
    if output_log:
        with open(output_log, "w") as f:
            subprocess.check_call(command, stdout=f, shell=True)
    else:
        subprocess.check_call(command, shell=True)


def get_model_perf(input_logfile):
    with open(input_logfile, "r") as profile_log:
        average_stats = False
        for line in profile_log:
            if line.strip() == "Execute Stats (Average):":
                average_stats = True
            elif average_stats and "NetRun:" in line:
                return int(line.strip().split(":")[1].strip().split(" ")[0]) / 1000
    raise ValueError(f"No Inference logs found in {input_logfile}!")


def run_scheduler(scheduler, noise_pred_uncond, noise_pred_text, latent_in, timestep):
    # ✅ CFG merge in numpy — avoids creating 3 extra torch tensors
    noise_pred_np = noise_pred_uncond + user_text_guidance * (noise_pred_text - noise_pred_uncond)
    # Only 2 torch tensors needed for scheduler.step()
    noise_pred_t = torch.from_numpy(np.ascontiguousarray(np.transpose(noise_pred_np, (0, 3, 1, 2))))
    latent_t     = torch.from_numpy(np.ascontiguousarray(np.transpose(latent_in,     (0, 3, 1, 2))))
    latent_out   = scheduler.step(noise_pred_t, timestep, latent_t, return_dict=False)[0].numpy()
    return np.ascontiguousarray(np.transpose(latent_out, (0, 2, 3, 1)))


def run_tokenizer(prompt, tokenizer):
    token_ids = tokenizer(
        prompt or "",
        padding="max_length",
        max_length=tokenizer_max_length,
        truncation=True
    ).input_ids
    # Model expects rank-2 input [batch=1, seq_len]
    return np.array(token_ids, dtype=np.int32).reshape(1, -1)


def cleanup_tmp():
    global _config_generated_for
    if os.path.exists(tmp_dirpath):
        shutil.rmtree(tmp_dirpath)
    _config_generated_for = None


# ─── Session server connection ────────────────────────────────────────────────
# Sessions are kept alive in session_server.py (a separate persistent process).
# Start the server ONCE before running this script:
#   python session_server.py
#
# Workflow
# --------
# 1. Script connects to the server and obtains a SessionStore proxy.
# 2. get_session() returns a _ServerSession wrapper for the named model.
# 3. _ServerSession.run() calls store.run_session() — the server runs
#    inference on its cached ort.InferenceSession and returns the outputs.
# 4. No ort.InferenceSession is ever created in this process.

_SERVER_HOST    = "127.0.0.1"
_SERVER_PORT    = 50001
_SERVER_AUTHKEY = b"sd3-ort-server"


class _SessionManager(BaseManager):
    pass


_SessionManager.register("SessionStore")

_manager  = None
_store    = None          # proxy to the server-side SessionStore
_sessions: dict = {}      # name -> _ServerSession wrapper (cached per process)


def _get_store():
    """Connect to the session server (lazy, once per process) and return the store proxy."""
    global _manager, _store
    if _manager is None:
        _manager = _SessionManager(
            address=(_SERVER_HOST, _SERVER_PORT),
            authkey=_SERVER_AUTHKEY,
        )
        _manager.connect()
        print(f"[client] Connected to session server at {_SERVER_HOST}:{_SERVER_PORT}", flush=True)
        _store = _manager.SessionStore()
    return _store


class _ServerSession:
    """
    Thin client-side wrapper for a server-side ort.InferenceSession.

    The server pre-loads all sessions at startup.  This wrapper simply
    forwards run() and get_inputs() calls to the server by name — no paths,
    no provider options, no local session creation.

    run()        → store.run_session(name, feeds)
    get_inputs() → store.get_input_names(name)  [cached after first call]
    get_outputs()→ [] (callers fall back to index-based output access)
    """

    def __init__(self, name: str):
        self._name         = name
        self._input_names:  list | None = None   # fetched lazily from server
        self._output_names: list | None = None   # fetched lazily from server

    def get_inputs(self):
        if self._input_names is None:
            store = _get_store()
            self._input_names = store.get_input_names(self._name)
        # Return mock objects with a .name attribute — matches ort.NodeArg interface
        return [type("_NodeArg", (), {"name": n})() for n in self._input_names]

    def get_outputs(self):
        if self._output_names is None:
            store = _get_store()
            self._output_names = store.get_output_names(self._name)
        # Return mock objects with a .name attribute — matches ort.NodeArg interface
        return [type("_NodeArg", (), {"name": n})() for n in self._output_names]

    def run(self, output_names, feeds: dict) -> list:
        store = _get_store()
        return store.run_session(self._name, feeds)


def get_session(name: str, model_path: str = "") -> _ServerSession:
    """
    Return the _ServerSession wrapper for *name*.

    The wrapper is created once per process and cached.  All inference calls
    are forwarded to the server, which holds the pre-loaded ort.InferenceSession.
    model_path is accepted for API compatibility but is not used — the server
    already knows the paths from its own startup configuration.
    """
    if name not in _sessions:
        print(f"[client] Connecting to session '{name}' on server ...", flush=True)
        _sessions[name] = _ServerSession(name)
        print(f"[client] Session '{name}' ready (server-side).", flush=True)
    return _sessions[name]


def _timed_run(sess, feeds: dict, label: str) -> list:
    """Call session.run() directly on the local session, record latency, return outputs."""
    import time
    t0 = time.perf_counter()
    outputs = sess.run(None, feeds)
    ms = (time.perf_counter() - t0) * 1000
    # Accumulate per-model timing
    if label not in model_inference_time:
        model_inference_time[label] = []
    model_inference_time[label].append(round(ms, 2))
    return outputs


def get_transformer_session(model_path: str):
    return get_session("transformer", model_path)


def get_te1_session(model_path: str):
    return get_session("text_encoder", model_path)


def get_te2_session(model_path: str):
    return get_session("text_encoder_2", model_path)


def get_vae_session(model_path: str):
    return get_session("vae_decoder", model_path)


def _te_model_path(name: str) -> str:
    return os.path.join(context_binaries_path, f"{name}_qnn_ctx_fp32_io.onnx")


# ─── Text Encoders (ORT) ──────────────────────────────────────────────────────
# No text_encoder_3 (T5-XXL) in this export — the transformer's encoder_hidden_states
# still reserves the T5 slot (seq positions 77:154), which is zero-filled instead
# (matches diffusers' SD3 pipeline behavior when text_encoder_3=None).

def run_text_encoder(input_data, text_encoder_name, evaluate_perf=False):
    """Run CLIP text encoder via ORT QNN EP.
    Returns (prompt_embeds [1,seq,D], pooled_prompt_embeds [1,D]).
    """
    sess = get_te1_session(_te_model_path('text_encoder')) if text_encoder_name == 'text_encoder' \
           else get_te2_session(_te_model_path('text_encoder_2'))

    outputs  = _timed_run(sess, {sess.get_inputs()[0].name: input_data}, text_encoder_name)
    out_map  = {o.name: arr for o, arr in zip(sess.get_outputs(), outputs)}
    hidden_states = out_map.get("hidden_states", outputs[0])
    text_embeds   = out_map.get("text_embeds",   outputs[1])
    return hidden_states.reshape((1, -1, hidden_states.shape[-1])), text_embeds.reshape((1, -1))


# ─── Transformer (ORT) ────────────────────────────────────────────────────────

# Pre-compute reshape constants once (512x512 export: H/8=64, HW/256=1024)
_TR_PATH = os.path.join(context_binaries_path, "transformer_qnn_ctx_fp32_io.onnx")
_HW256   = int(height * width / 256)   # 1024
_H16     = int(height / 16)            # 32
_W16     = int(width  / 16)            # 32
_H8      = int(height / 8)             # 64
_W8      = int(width  / 8)             # 64


def _unpack_noise_pred(raw):
    """Unpack packed transformer output -> NHWC (1, H/8, W/8, 16)."""
    return (raw
            .reshape(1, _HW256, 64)
            .reshape(1, _H16, _W16, 2, 2, 16)
            .transpose(0, 5, 1, 3, 2, 4)
            .reshape(1, 16, _H8, _W8)
            .transpose(0, 2, 3, 1))


def run_transformer(pooled_projections, encoder_hidden_states, hidden_states, timestep,
                    evaluate_perf=False):
    """Single-sample transformer call.

    The exported graph takes the raw scalar timestep directly (time-embedding math
    is baked into the QNN graph) and does not support batch_size=2, so uncond/cond
    are run as two separate calls per denoising step.
    """
    sess = get_transformer_session(_TR_PATH)
    outputs = _timed_run(sess, {
        "pooled_projections_dq":    np.ascontiguousarray(pooled_projections,    dtype=np.float32),
        "encoder_hidden_states_dq": np.ascontiguousarray(encoder_hidden_states, dtype=np.float32),
        "hidden_states_dq":         np.ascontiguousarray(hidden_states,         dtype=np.float32),
        "timestep_dq":              np.ascontiguousarray(timestep,              dtype=np.float32),
    }, 'transformer')
    return _unpack_noise_pred(outputs[0])


# ─── VAE (ORT) ────────────────────────────────────────────────────────────────

def run_vae(latent_in_vae, evaluate_perf=False):
    """Run VAE decoder via ORT QNN EP. Returns uint8 RGB image [H,W,3]."""
    sess    = get_vae_session(os.path.join(context_binaries_path, "vae_decoder_qnn_ctx_fp32_io.onnx"))
    outputs = _timed_run(sess, {sess.get_inputs()[0].name: np.ascontiguousarray(latent_in_vae, dtype=np.float32)}, 'vae')

    output_data = outputs[0]
    return np.clip((output_data / 2 + 0.5) * 255.0, 0, 255).astype(np.uint8).reshape((height, width, 3))


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    import time
    start = time.perf_counter()

    parser = argparse.ArgumentParser(description="Generate image using SD3 Medium model")
    parser.add_argument("-p",  "--prompt",          type=str, required=True)
    parser.add_argument("-np", "--negative_prompt", type=str,
                        default="animated, blurry, low resolution, bad quality, cartoon, not-real, "
                                "malformed, unbalanced, composition, watermark")
    args = parser.parse_args()

    user_prompt          = args.prompt
    user_negative_prompt = args.negative_prompt or ""
    sys.path.insert(0, os.path.dirname(__file__))

    assert isinstance(user_seed, np.int64)
    assert isinstance(user_step, int)
    assert isinstance(user_text_guidance, float)
    assert 0.0 <= user_text_guidance <= 15.0

    os.environ["TOKENIZERS_PARALLELISM"] = "0"

    # ── Scheduler ─────────────────────────────────────────────────────────────
    scheduler = FlowMatchEulerDiscreteScheduler(num_train_timesteps=1000, shift=3.0)
    scheduler.set_timesteps(user_step)
    timesteps = scheduler.timesteps

    # ── Tokenizers ────────────────────────────────────────────────────────────
    # Loaded from the stabilityai/stable-diffusion-3.5-medium repo's tokenizer/
    # tokenizer_2 subfolders (plain CLIPTokenizer, same as openai/clip-vit-large-patch14
    # and laion/CLIP-ViT-bigG-14-laion2B-39B-b160k) — uses the default HF cache
    # (~/.cache/huggingface) so an existing local snapshot is reused offline instead
    # of requiring a fresh download of the standalone repos.
    print("Loading tokenizers ...", flush=True)
    tokenizer1 = CLIPTokenizer.from_pretrained(
        "stabilityai/stable-diffusion-3.5-medium",
        subfolder="tokenizer",
    )

    tokenizer2 = CLIPTokenizer.from_pretrained(
        "stabilityai/stable-diffusion-3.5-medium",
        subfolder="tokenizer_2",
    )

    # ── Tokenize ──────────────────────────────────────────────────────────────
    print("Tokenizing prompts ...", flush=True)
    uncond_tokens    = run_tokenizer(user_negative_prompt, tokenizer1)
    cond_tokens      = run_tokenizer(user_prompt,          tokenizer1)
    uncond_tokens_2  = run_tokenizer(user_negative_prompt, tokenizer2)
    cond_tokens_2    = run_tokenizer(user_prompt,          tokenizer2)

    # ── Text Encoders (ORT) ───────────────────────────────────────────────────
    print("Running text encoders via ORT ...", flush=True)
    uncond_text_emb_1, pooled_uncond_text_emb_1 = run_text_encoder(uncond_tokens,   'text_encoder')
    user_text_emb_1,   pooled_user_text_emb_1   = run_text_encoder(cond_tokens,     'text_encoder')
    uncond_text_emb_2, pooled_uncond_text_emb_2 = run_text_encoder(uncond_tokens_2, 'text_encoder_2')
    user_text_emb_2,   pooled_user_text_emb_2   = run_text_encoder(cond_tokens_2,   'text_encoder_2')

    # ── Assemble embeddings (pure numpy — no torch overhead) ─────────────────
    def assemble_embeds(emb1, emb2):
        # Concatenate CLIP embeddings along feature dim, pad to match T5 width.
        # No text_encoder_3 in this export — the T5 slot is zero-filled.
        clip_padded = np.pad(
            np.concatenate([emb1, emb2], axis=-1).astype(np.float32),
            ((0, 0), (0, 0), (0, 2048))
        )
        t5_slot = np.zeros((1, 77, 4096), dtype=np.float32)
        zeros   = np.zeros((1, 6, 4096), dtype=np.float32)
        return np.concatenate([clip_padded, t5_slot, zeros], axis=1)

    uncond_text_emb = assemble_embeds(uncond_text_emb_1, uncond_text_emb_2)
    user_text_emb   = assemble_embeds(user_text_emb_1,   user_text_emb_2)

    # Pooled embeddings: pure numpy concat, [1, 2048]
    pooled_uncond_text_emb = np.concatenate(
        [pooled_uncond_text_emb_1, pooled_uncond_text_emb_2], axis=-1
    ).astype(np.float32)
    pooled_user_text_emb = np.concatenate(
        [pooled_user_text_emb_1, pooled_user_text_emb_2], axis=-1
    ).astype(np.float32)

    # ── Initial latent ────────────────────────────────────────────────────────
    latent_in = (torch.randn((1, 16, height // 8, width // 8),
                             generator=torch.manual_seed(user_seed))
                 .numpy().transpose((0, 2, 3, 1)).copy())

    # Pre-ensure contiguous float32 once — avoids per-step ascontiguousarray overhead
    uncond_text_emb_c = np.ascontiguousarray(uncond_text_emb, dtype=np.float32)
    user_text_emb_c   = np.ascontiguousarray(user_text_emb,   dtype=np.float32)

    # ── Denoising Loop ────────────────────────────────────────────────────────
    # The exported transformer graph takes the raw scalar timestep directly
    # (no separate time-embedding module/checkpoint needed).
    for i, t in enumerate(timesteps):
        print(f"Step {i + 1}/{user_step} ...", flush=True)
        ts = np.array([float(t)], dtype=np.float32)
        uncond_noise = run_transformer(pooled_uncond_text_emb, uncond_text_emb_c, latent_in, ts)
        cond_noise   = run_transformer(pooled_user_text_emb,   user_text_emb_c,   latent_in, ts)
        latent_in    = run_scheduler(scheduler, uncond_noise, cond_noise, latent_in, t)

    # ── VAE Decode ────────────────────────────────────────────────────────────
    vae_scaling_factor = 1.5305
    vae_shift_factor   = 0.0609
    output_images = run_vae((latent_in / vae_scaling_factor) + vae_shift_factor)

    # ── Save Output ───────────────────────────────────────────────────────────
    os.makedirs(r"C:\Users\HCKTest\.openclaw\workspace\Output\images", exist_ok=True)
    out_img_path = fr"C:\Users\HCKTest\.openclaw\workspace\Output\images\sd3_npu_output_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
    Image.fromarray(output_images, mode="RGB").save(out_img_path)
    print(f"Image saved: {out_img_path}", flush=True)
    print(f"Time taken : {time.perf_counter() - start:.2f}s", flush=True)

    grand_total_sec = 0
    for label, times in model_inference_time.items():
        total_sec = sum(times)
        avg_sec   = (sum(times) / len(times))
        grand_total_sec += total_sec
        print(f"[{label}] calls: {len(times)} | total: {total_sec:.3f}ms | avg: {avg_sec:.3f}ms")
    print(f"\nAll model inference total time: {(grand_total_sec/1000):.3f}s")

if __name__ == "__main__":
    main()
