---
name: image-generation
description: Generate images via the Cirrascale AI Suite cloud API (text-to-image) or the local SD2.1 NPU pipeline, and save/embed the results. Supports a hybrid split — a 3-image request goes 1 to local SD2.1 (NPU) and 2 to Cirrascale SDXL. Use for any decor, theme, or setup idea request — decor ideas are always delivered as generated images, not text-only descriptions.
metadata:
  { "openclaw": { "primaryEnv": "CIRRASCALE_API_KEY", "emoji": "🖼️" } }
---

# SKILL.md — image-generation

## Overview

| Field       | Details                                                                 |
|-------------|--------------------------------------------------------------------------|
| **Name**    | image-generation                                                         |
| **Type**    | Text-to-Image Generation (Cirrascale AI Suite cloud API)                 |
| **Script**  | `generate_cli.py` (cloud) · `Stable-Diffusion-2-1/generate.py` (local NPU) |
| **Backend** | `https://aisuite.cirrascale.com/apis/v2/images/generations` · local Snapdragon NPU (ORT-QNN) |

**Description:**
Cloud image generation via the Cirrascale AI Suite images API (default model
`stabilityai/sdxl-turbo`). Sends a prompt over HTTPS and saves the returned
image(s) to disk.

This skill also has a **local** backend: Stable Diffusion 2.1 running on the
Qualcomm Snapdragon NPU (see `Stable-Diffusion-2-1/SKILL.md`). Multi-image
requests are split across both — see "Hybrid setup" below.

This skill takes a prompt as-is — it does not expand or embellish it. Turning
the owner's short request into a detailed, vivid image-generation prompt is
the calling agent's job, done before invoking this CLI (see `AGENTS.md` →
"CLOUD IMAGE GENERATION").

---

## ⚠️ CRITICAL

> Requires `CIRRASCALE_API_KEY` set in `.env` (repo root). Never hardcode the
> key in a script, prompt, or commit — it's a live bearer credential.
> Always invoke `generate_cli.py`. NEVER modify the script.

---

## Invocation

### Setup (once)
```bash
pip install -r requirements.txt
```
Add to `.env` at the repo root:
```
CIRRASCALE_API_KEY=<your-cirrascale-bearer-token>
```

### Command
```bash
python generate_cli.py "<prompt>" [options]
```

### Example
```bash
python generate_cli.py "a fairy-light-draped balloon arch, warm golden hour" \
    --model stabilityai/sdxl-turbo --size 512x512 --steps 1 --guidance-scale 6.5
```

### Arguments

| Argument         | Flag                  | Required | Default                  | Description                                    |
|------------------|-----------------------|----------|---------------------------|-------------------------------------------------|
| Prompt           | *(positional)*        | ✅ Yes   | —                         | Image prompt as a quoted string                |
| Model            | `--model`             | ❌ No    | `stabilityai/sdxl-turbo`  | Cirrascale model identifier                    |
| Size             | `--size`              | ❌ No    | `512x512`                 | `WIDTHxHEIGHT`                                 |
| Count            | `--n`                 | ❌ No    | `1`                       | Number of images to generate                   |
| Inference steps  | `--steps`             | ❌ No    | `1`                       | `num_inference_steps`                          |
| Guidance scale   | `--guidance-scale`    | ❌ No    | `6.5`                     | Prompt adherence strength                      |
| Seed             | `--seed`              | ❌ No    | *(none)*                  | Fixed seed for reproducibility                 |
| Seed increment   | `--seed-increment`    | ❌ No    | *(none)*                  | Per-image seed step when `n > 1`               |
| Response format  | `--response-format`   | ❌ No    | `b64_json`                | `b64_json` (saved to disk) or `url`            |
| Output dir       | `--output-dir`        | ❌ No    | `Skills/image-generation/output` (workspace-relative) | Where decoded images are saved |
| Filename prefix  | `--prefix`            | ❌ No    | `cirrascale`              | Prefix for saved filenames                     |
| Timeout          | `--timeout`           | ❌ No    | `90`                      | Request timeout in seconds                      |
| JSON output      | `--json`              | ❌ No    | off                       | Emit a JSON summary instead of text             |

Note: the script always calls the API with `stream=true` internally — Cirrascale's
non-streaming mode was confirmed to hang 90s+ with no response, so there is no
`--stream` flag to turn off.

---

## Trigger Conditions

Invoke this skill when the user:

- Asks for decor ideas, theme ideas, setup ideas, or a look/concept for an event
  — even when they never say the word "image". "I want a decor idea for a
  birthday with blue balloons and a yellow backdrop" is an image request.
- Asks to generate an image via the cloud, an API, or names "Cirrascale" specifically
- Asks for image generation
- Names a Cirrascale-hosted model (e.g. `stabilityai/sdxl-turbo`) directly
- Asks for **three** images/ideas/concepts — that request is hybrid: 1 local
  SD2.1 on the NPU + 2 Cirrascale SDXL (see "Hybrid setup")
- Asks for local/NPU/SD2.1 generation explicitly — route to the local backend

A decor idea answered as text only is an incomplete answer. Write the text
description *and* run the CLI to produce the image for it. When the request
implies several distinct concepts, generate one image per concept.

### ⚠️ Run multi-image requests sequentially

Call the CLI once per concept, **waiting for each call to finish before
starting the next**. Never launch several `generate_cli.py` calls in parallel.

Cirrascale silently drops concurrent requests: the extra ones come back as
HTTP 200 with `content-type: text/event-stream` and an *empty body* — no
`data:` event — so `_call_streaming` returns nothing and the CLI exits 2 with
`ERROR: no response payload from Cirrascale API`. Measured on this deployment:

| Mode          | Outcome                          |
|---------------|----------------------------------|
| 3 in parallel | 1 image, 2 errors                |
| 2 in parallel | 2 images, but 45s and 56s each   |
| 3 sequential  | 3 images, ~24s each              |

Budget ~24s per image, so three concepts take ~75s. That is normal, not a hang.

If you asked for N concepts, you must end up with N entries across the calls'
`saved_paths`. Fewer means a call failed — say so and re-run the missing one;
never deliver N prompts with fewer than N images.

---

## Hybrid setup (local NPU + cloud)

A **3-image request splits across both backends**: 1 image on the local SD2.1
NPU pipeline, 2 images on Cirrascale SDXL. This applies whenever three images
are asked for — "3 decor ideas", "give me three concepts", "generate 3 images".

| Image | Backend | Model | Script | Prompt style |
|-------|---------|-------|--------|--------------|
| 1 | **Local NPU** (Snapdragon, ORT-QNN) | Stable Diffusion 2.1 | `Stable-Diffusion-2-1/generate.py` | **Simple** — one short decor idea, ~10–15 words |
| 2 | Cirrascale cloud | `stabilityai/sdxl-turbo` | `generate_cli.py` | Full detailed prompt (style, lighting, palette, composition) |
| 3 | Cirrascale cloud | `stabilityai/sdxl-turbo` | `generate_cli.py` | Full detailed prompt |

Other counts do not split: 1 or 2 images → all Cirrascale; 4 images → the
four-concept decor flow via `concepts_cli.py` (all Cirrascale). Only route to
the local NPU outside a 3-image request when the owner asks for it explicitly
("use the NPU", "run it locally", "use SD2.1").

### Prompt rules per backend

- **SD2.1 (local NPU) — keep the prompt simple.** SD2.1 at 20 steps on the NPU
  handles a plain, concrete decor idea far better than a dense one. Write one
  short decor concept: subject, colors, setting. No multi-clause camera/lighting
  stacking, no long modifier chains.
  - ✅ `"birthday table with blue balloons and a yellow backdrop"`
  - ❌ `"ultra-detailed cinematic 8k birthday tablescape, volumetric golden-hour
    rim lighting, shallow depth of field, pastel cobalt balloon cluster..."`
- **Cirrascale SDXL — expand fully**, exactly as the rest of this file describes.
  The two cloud concepts must be visually distinct from each other *and* from
  the SD2.1 one.

### Step 0 — start the local session server (once, kept running)

`generate.py` will not run without it. Check the port first; only start it if
nothing is listening on `127.0.0.1:50002`:

```bash
netstat -ano | findstr :50002
```

```bash
Skills\image-generation\Stable-Diffusion-2-1\venv\Scripts\python.exe ^
  Skills\image-generation\Stable-Diffusion-2-1\session_server.py
```

Leave it running in the background — it holds the pre-loaded ORT-QNN sessions.
First load takes a while; that is normal.

### Calls

Local (image 1) — use the pipeline's own venv, and save into the shared output
directory so the path can be embedded like any other:

```bash
Skills\image-generation\Stable-Diffusion-2-1\venv\Scripts\python.exe ^
  Skills\image-generation\Stable-Diffusion-2-1\generate.py ^
  --prompt "<simple decor idea>" ^
  --steps 20 --guidance-scale 7.5 --seed 42 ^
  --output "Skills\image-generation\output\concept1_sd21.png"
```

Cloud (images 2 and 3) — one at a time, as always:

```bash
python ".\Skills\image-generation\generate_cli.py" "<detailed prompt 2>" --prefix concept2 --json
python ".\Skills\image-generation\generate_cli.py" "<detailed prompt 3>" --prefix concept3 --json
```

Ordering: the two Cirrascale calls stay strictly sequential — that restriction
is Cirrascale-side only. The local NPU call may be started alongside them, since
it never touches the API. Budget ~24s per cloud image; the local one is slower.

### Reporting

Label the backend for each image in the reply — the owner needs to know which
one came off the NPU:

```markdown
![Concept 1 — blue balloons, yellow backdrop](Skills/image-generation/output/concept1_sd21.png)
*Concept 1 — Stable Diffusion 2.1, generated locally on the Snapdragon NPU*

![Concept 2 — ...](Skills/image-generation/output/concept2_<ts>_0.png)
*Concept 2 — SDXL-Turbo via Cirrascale cloud*
```

Three images asked for means three images delivered. If the local call fails
(server not running, NPU busy), say so explicitly and name the backend that
failed — do not silently generate the third image on Cirrascale instead.

---

## Expected Output

- One or more images saved under `--output-dir` (default `Skills/image-generation/output/`,
  workspace-relative) as `<prefix>_<timestamp>_<index>.png` when
  `--response-format b64_json` (default)
- Printed URLs instead, if `--response-format url` is used
- With `--json`, a `{"saved_paths": [...], "urls": [...]}` summary — after calling
  this skill, embed each `saved_paths` entry inline as a markdown image
  (`![<short description>](<path>)`) in your reply so the owner sees the actual
  image, not just a file path
- Non-zero exit code and an `ERROR:` line on stderr for missing config, bad
  input, or an API-level failure — report the error, do not silently retry with
  different parameters

---

## Do NOT

- ❌ Hardcode the Cirrascale API key anywhere — it must come from `CIRRASCALE_API_KEY` in `.env`
- ❌ Modify `generate_cli.py`
- ❌ Skip this skill because of a perceived error — report the error, do not work around it
