# SKILL.md — sd3-image-generation

## Overview

| Field       | Details                                                                 |
|-------------|-------------------------------------------------------------------------|
| **Name**    | sd3-image-generation                                                     |
| **Type**    | Text-to-Image Generation (Local NPU only)                               |
| **Script**  | `SD3_Tool.py`                                                           |
| **Hardware**| Qualcomm Snapdragon NPU via ONNX Runtime QNN execution provider         |

**Description:**
Local-only image generation skill for Stable Diffusion 3 Medium, accelerated on a Qualcomm
Snapdragon NPU. Pass a prompt to `SD3_Tool.py` — it runs the full text-encode → denoise → VAE
decode pipeline against the persistent `session_server.py` process and saves the result.

---

## ⚠️ CRITICAL

> `session_server.py` MUST be running before `SD3_Tool.py` is invoked — it holds the pre-loaded
> ORT-QNN sessions that `SD3_Tool.py` connects to.
> Always invoke `SD3_Tool.py` for generation. NEVER call any other script directly.
> NEVER modify any script.

---

## Invocation

### Step 0 — start the session server (once, kept running)
```bash
python "C:\mounika\DecoAI\sd3_ort_qnn\session_server.py"
# Optional: specify a custom model directory
python "C:\mounika\DecoAI\sd3_ort_qnn\session_server.py" --model_dir C:\path\to\Model_Bins
```
Leave this process running in the background. It listens on `127.0.0.1:50001`.

### Command
```bash
python "C:\mounika\DecoAI\sd3_ort_qnn\SD3_Tool.py" --prompt "prompt text" [--negative_prompt "negative prompt text"]
```

### Example
```bash
python "C:\mounika\DecoAI\sd3_ort_qnn\SD3_Tool.py" --prompt "Taipei night market neon hero shot"
```

### Arguments

| Argument         | Flag                    | Required | Description                                              |
|------------------|-------------------------|----------|------------------------------------------------------------|
| Prompt           | `-p`, `--prompt`        | ✅ Yes   | Image prompt as a quoted string                           |
| Negative prompt  | `-np`, `--negative_prompt` | ❌ No | Negative prompt (default: a generic quality/composition guard) |

---

## Trigger Conditions

Invoke this skill when the user:

- Says "generate an image", "create a picture", "draw", "make an image of..." AND local/NPU
  generation is specifically requested (e.g. "use the NPU", "generate locally", "use SD3")
- Provides a descriptive text prompt intended to produce a visual output via the local SD3
  pipeline specifically
- Uses words like "visualize", "illustrate", "render", "show me" in the context of the local
  SD3 Medium pipeline

---

## Expected Output

- One image saved to `C:\Users\HCKTest\.openclaw\workspace\Output\images\sd3_npu_output_<timestamp>.png`
- Console prints per-step denoising progress and a final per-model inference timing summary

---

## Do NOT

- ❌ Call `SD3_Tool.py` before `session_server.py` is running
- ❌ Call any script other than `SD3_Tool.py` for generation
- ❌ Use any cloud image generation tool or API directly
- ❌ Modify any script
- ❌ Skip this skill because of a perceived error — report the error, do not work around it
