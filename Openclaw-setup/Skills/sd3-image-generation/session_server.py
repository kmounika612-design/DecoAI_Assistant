#!/usr/bin/env python3
"""
session_server.py – Persistent ONNX Runtime session server (separate process).

Start this process ONCE before running SD3_Tool.py:
    python session_server.py [--model_dir <path>]

Architecture
------------
All four ONNX sessions are created at server startup and kept alive in memory.
By the time the client connects, every session is already loaded and the QNN
HTP hardware is warm.

The client calls store.run_session(name, feeds) — the server looks up the
pre-loaded session by name, runs inference, and returns the output arrays.
No session is ever created in the client process.

Arguments
---------
  --model_dir   Directory containing the four *_qnn_ctx_fp32_io.onnx files.
                Defaults to <cwd>/Model_Bins.

Exposed methods (via multiprocessing.managers)
----------------------------------------------
  run_session(name, feeds)   -> list[np.ndarray]
  get_input_names(name)      -> list[str]
"""
import argparse
import os
import platform
import sys
from multiprocessing.managers import BaseManager
import onnxruntime as ort


# ─── QAIRT SDK (must match the SDK version the context binaries were built
# against — the pip-installed onnxruntime-qnn package bundles an older
# QnnHtp.dll that cannot load newer context binaries) ─────────────────────────
QAIRT_SDK_ROOT = r"C:\Users\HCKTest\Downloads\qairt-sdk-v2.43.0.260128150333_193827\qairt\2.43.0.260128"


def _qairt_lib_dir() -> str:
    arch_dir = "aarch64-windows-msvc" if platform.machine().lower() in ("arm64", "aarch64") \
               else "x86_64-windows-msvc"
    return os.path.join(QAIRT_SDK_ROOT, "lib", arch_dir)


_QAIRT_LIB_DIR = _qairt_lib_dir()
os.environ["PATH"] = _QAIRT_LIB_DIR + os.pathsep + os.environ.get("PATH", "")

# ─── Model registry ──────────────────────────────────────────────────────────
# Maps logical session name -> ONNX filename (relative to --model_dir)
MODELS = {
    "text_encoder":   "text_encoder_qnn_ctx_fp32_io.onnx",
    "text_encoder_2": "text_encoder_2_qnn_ctx_fp32_io.onnx",
    "transformer":    "transformer_qnn_ctx_fp32_io.onnx",
    "vae_decoder":    "vae_decoder_qnn_ctx_fp32_io.onnx",
}

# QNN HTP execution provider options
QNN_PROVIDER_OPTIONS = {
    "backend_path":                             os.path.join(_QAIRT_LIB_DIR, "QnnHtp.dll"),
    "htp_graph_finalization_optimization_mode": "3",
    "htp_performance_mode":                     "burst",
    "vtcm_mb":                                  "8",
}

# ─── Server-side session registry ────────────────────────────────────────────
# Populated at startup; shared across all SessionStore instances.
_sessions: dict[str, ort.InferenceSession] = {}


# ─── Managed object ──────────────────────────────────────────────────────────
class SessionStore:
    """Exposed to clients via multiprocessing.managers.

    Sessions are pre-loaded at server startup — this class only provides
    access to them.
    """

    def run_session(self, name: str, feeds: dict) -> list:
        """Run inference on the named pre-loaded session.

        Parameters
        ----------
        name  : one of 'text_encoder', 'text_encoder_2', 'transformer', 'vae_decoder'
        feeds : dict {input_name: np.ndarray}

        Returns
        -------
        list[np.ndarray] – inference outputs (copied by value to the client)
        """
        if name not in _sessions:
            raise KeyError(
                f"[server] Session '{name}' is not loaded. "
                f"Available: {list(_sessions.keys())}"
            )
        print(f"[server] run_session '{name}'", flush=True)
        return _sessions[name].run(None, feeds)

    def get_input_names(self, name: str) -> list:
        """Return the list of input tensor names for the named session.

        Returns a plain list[str] — copied by value to the client.
        """
        if name not in _sessions:
            raise KeyError(
                f"[server] Session '{name}' is not loaded. "
                f"Available: {list(_sessions.keys())}"
            )
        return [inp.name for inp in _sessions[name].get_inputs()]

    def get_output_names(self, name: str) -> list:
        """Return the list of output tensor names for the named session.

        Returns a plain list[str] – copied by value to the client.
        """
        if name not in _sessions:
            raise KeyError(
                f"[server] Session '{name}' is not loaded. "
                f"Available: {list(_sessions.keys())}"
            )
        return [out.name for out in _sessions[name].get_outputs()]


# ─── Manager definition ───────────────────────────────────────────────────────
class SessionManager(BaseManager):
    pass


SessionManager.register("SessionStore", SessionStore)

# ─── Entry point ──────────────────────────────────────────────────────────────
SERVER_HOST    = "127.0.0.1"
SERVER_PORT    = 50001
SERVER_AUTHKEY = b"sd3-ort-server"

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Persistent ORT session server for SD3 Medium"
    )
    parser.add_argument(
        "--model_dir",
        default=os.path.join(os.getcwd(), "Model_Bins"),
        help="Directory containing the *_qnn_ctx_fp32_io.onnx model files "
             "(default: <cwd>/Model_Bins)",
    )
    args = parser.parse_args()

    # ── Pre-load all sessions ─────────────────────────────────────────────────
    print(f"[server] Loading sessions from: {args.model_dir}", flush=True)
    for name, filename in MODELS.items():
        path = os.path.join(args.model_dir, filename)
        print(f"[server] Loading '{name}' from {path} ...", flush=True)
        so = ort.SessionOptions()
        _sessions[name] = ort.InferenceSession(
            path,
            sess_options=so,
            providers=["QNNExecutionProvider"],
            provider_options=[QNN_PROVIDER_OPTIONS],
        )
        print(f"[server] '{name}' ready.", flush=True)

    print(f"[server] All {len(_sessions)} sessions loaded.", flush=True)

    # ── Start serving ─────────────────────────────────────────────────────────
    manager = SessionManager(
        address=(SERVER_HOST, SERVER_PORT),
        authkey=SERVER_AUTHKEY,
    )
    server = manager.get_server()
    print(f"[server] Listening on {SERVER_HOST}:{SERVER_PORT}", flush=True)
    print("[server] Press Ctrl-C to stop.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[server] Shutting down.", flush=True)
        sys.exit(0)
