# SKILL.md — sd2.1-image-generation

## Overview

| Field       | Details                                                                 |
|-------------|-------------------------------------------------------------------------|
| **Name**    | sd2.1-image-generation                                                  |
| **Type**    | Text-to-Image Generation (Local NPU only)                               |
| **Script**  | `generate.py`                                                           |
| **Hardware**| Qualcomm Snapdragon NPU via ONNX Runtime QNN execution provider         |

**Description:**
Local-only image generation skill for Stable Diffusion 2.1, accelerated on a Qualcomm
Snapdragon NPU. Pass a prompt to `generate.py` — it runs the full text-encode → denoise →
VAE decode pipeline against the persistent `session_server.py` process and saves the result.

---

## ⚠️ CRITICAL

> `session_server.py` MUST be running before `generate.py` is invoked — it holds the
> pre-loaded ORT-QNN sessions that `generate.py` connects to.
> Always invoke `generate.py` for generation. NEVER call any other script directly.
> NEVER modify any script.
> This pipeline requires `onnxruntime-qnn==2.4.0` (plugin EP, bundles QAIRT SDK 2.48) —
> older SDK DLLs cannot load this model's context binaries.

---

## Invocation

### Step 0 — start the session server (once, kept running)
```bash
python "C:\hackathon_code\sd2.1_ort_qnn\session_server.py"
# Optional: specify a custom model directory
python "C:\hackathon_code\sd2.1_ort_qnn\session_server.py" --model_dir C:\path\to\Model_Bins
```
Leave this process running in the background. It listens on `127.0.0.1:50002`.

### Command
```bash
python "C:\hackathon_code\sd2.1_ort_qnn\generate.py" --prompt "prompt text" [--negative-prompt "negative prompt text"] [--seed 42] [--steps 20] [--guidance-scale 7.5] [--output "output.png"]
```

### Example
```bash
python "C:\hackathon_code\sd2.1_ort_qnn\generate.py" --prompt "Taipei night market neon hero shot"
```

### Arguments

| Argument         | Flag                | Required | Description                                                        |
|------------------|----------------------|----------|----------------------------------------------------------------------|
| Prompt           | `--prompt`           | ✅ Yes   | Image prompt as a quoted string                                     |
| Negative prompt  | `--negative-prompt`  | ❌ No    | Unconditional/negative prompt (default: empty string)                |
| Seed             | `--seed`             | ❌ No    | Integer seed for the initial latent (default: `42`)                  |
| Steps            | `--steps`            | ❌ No    | Number of denoising steps, `20` or `50` (default: `20`)              |
| Guidance scale   | `--guidance-scale`   | ❌ No    | Classifier-free guidance scale, in `[5.0, 15.0]` (default: `7.5`)     |
| Output path      | `--output`           | ❌ No    | Path to save the generated PNG (default: `output.png` in the cwd)    |

---

## Trigger Conditions

Invoke this skill when the user:

- Says "generate an image", "create a picture", "draw", "make an image of..." AND local/NPU
  generation is specifically requested (e.g. "use the NPU", "generate locally", "use SD2.1")
- Provides a descriptive text prompt intended to produce a visual output via the local SD2.1
  pipeline specifically
- Uses words like "visualize", "illustrate", "render", "show me" in the context of the local
  SD2.1 pipeline

---

## Expected Output

- One image saved to the path given by `--output` (default: `output.png` in the working
  directory `generate.py` was run from)
- Console prints per-step denoising progress (timestep, tensor stats) and a final "Saved
  image to ..." confirmation

---

## Do NOT

- ❌ Call `generate.py` before `session_server.py` is running
- ❌ Call any script other than `generate.py` for generation
- ❌ Use any cloud image generation tool or API directly
- ❌ Modify any script
- ❌ Skip this skill because of a perceived error — report the error, do not work around it
