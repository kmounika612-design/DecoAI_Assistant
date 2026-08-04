# SKILL.md — image-generation (Hybrid)

## Overview

| Field       | Details                                                                 |
|-------------|-------------------------------------------------------------------------|
| **Name**    | image-generation                                                        |
| **Type**    | Text-to-Image Generation (Cloud + Local, Parallel)                      |
| **Script**  | `image_gen_hybrid.py`                                                   |
| **Hardware**| Qualcomm Snapdragon NPU (local) + Google Cloud (cloud)                  |

**Description:**
Hybrid image generation skill. Pass all prompts to `image_gen_hybrid.py` — it automatically
splits them between cloud and local models and runs both in parallel.

---

## ⚠️ CRITICAL

> Always invoke `image_gen_hybrid.py`. NEVER call any other script directly.
> NEVER modify any script.

---

## Invocation

### Command
```bash
python ".\skills\image-gen-hybrid\image_gen_hybrid.py" --prompts "prompt 1" "prompt 2" "prompt 3" ...
```

### ⚠️ exec parameters — MANDATORY
- **`background: false`** — must always be explicitly set to `false`
- **`yieldMs`** — must NOT be set (omit entirely)
- The exec call must block until the script exits before proceeding

### Example
```bash
python ".\skills\image-gen-hybrid\image_gen_hybrid.py" --prompts "Taipei night market neon hero shot" "beef noodle soup illustration" "stinky tofu street food card"
```

### Arguments

| Argument       | Flag          | Required | Description                                              |
|----------------|---------------|----------|----------------------------------------------------------|
| Prompts        | `--prompts`   | ✅ Yes   | One or more image prompts as space-separated quoted strings |
| Output dir     | `--output-dir`|  No    | Directory to save images (Defaults to `~\.openclaw\media\hybrid-images`)       |

---

## Trigger Conditions

Invoke this skill when the user:

- Says "generate an image", "create a picture", "draw", "make an image of..."
- Provides a descriptive text prompt intended to produce a visual output
- Uses words like "visualize", "illustrate", "render", "show me"

---

## Expected Output

- Images saved to `~\.openclaw\media\hybrid-images` by default
- Console prints per-image progress and final timing summary

---

## Do NOT

- ❌ Call any script other than `image_gen_hybrid.py`
- ❌ Use any cloud image generation tool or API directly
- ❌ Modify any script
- ❌ Skip this skill because of a perceived error — report the error, do not work around it
- ❌ Mention the output file path as text — always send images via the `message` tool with `media`

## Sending images after generation

After the script completes, send each image using the `message` tool with the `media` parameter set to the local file path:

```
message: { media: "C:\\Users\\HCKTest\\.openclaw\\workspace\\Output\\images\\image.png" }
```

Never paste the path as plain text. The `media` parameter causes Telegram to receive the actual image file.