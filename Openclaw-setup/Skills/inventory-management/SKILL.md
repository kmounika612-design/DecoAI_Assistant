# SKILL.md — inventory-management

## Overview

| Field       | Details                                                                 |
|-------------|-------------------------------------------------------------------------|
| **Name**    | inventory-management                                                     |
| **Type**    | Inventory CRUD + Invoice/Vision Intake (Shared SQLite DB)               |
| **Scripts** | `cli/invoice_cli.py`, `cli/image_cli.py`, `cli/refresh_cli.py`          |
| **Hardware**| Shared SQLite DB (`database/decoai.sqlite`) + Arduino Uno Q (optional)  |

**Description:**
Owner-facing inventory intake and stock-check skill. Three standalone CLIs cover the three
steps of the owner workflow — record a purchase, check a decoration photo against stock, and
refresh/reorder from live shelf counts. Each CLI talks to the shared inventory DB directly;
no server needs to be running.

---

## ⚠️ CRITICAL

> Always invoke the CLIs under `inventory-management\cli\`. NEVER call `app/main.py`'s FastAPI
> routes directly when a CLI already covers the task.
> NEVER modify any script.
> NEVER modify the shared DB schema (`database/schema.sql`).

---

## Invocation

### 1. Invoice upload — `decoai-invoice`

Extracts line items from a purchase invoice (image or PDF) and adds/restocks them in inventory.

**Primary flow — agent decides reusability/rent before committing:**

#### Step 1a: Extract only (no DB writes)
```bash
python "C:\mounika\DecoAI\inventory-management\cli\invoice_cli.py" <invoice-file> --extract-only
```
Prints the extraction JSON (`invoice_date` + `lines`), with `rent_ea: null` on every line.

#### Step 1b: Agent decides reusability and rent, per line
For each line, decide whether the item is reusable/rentable decor (lighting, furniture, linens,
structural pieces) vs. a consumable/one-time item (food, disposables, single-use favors). There
is no fixed formula — judge a sensible per-rental price from the item type, its `cost_ea`, and
typical event-rental market norms. Set `rent_ea` to that judged price if reusable, or `0` if not.
Write the finalized JSON (same shape, `rent_ea` filled in) to a scratch file.

#### Step 1c: Commit the finalized data
```bash
python "C:\mounika\DecoAI\inventory-management\cli\invoice_cli.py" --commit-file <scratch-file> [--json]
```
Upserts every line into the shared DB using the agent-decided `rent_ea` values.

> Reusability is **implicit**: `rent_ea > 0` means reusable/rentable, `rent_ea = 0` means not.
> There is no separate `is_reusable` column.
>
> Omitting `rent_ea` on a line (rather than setting it to `0`) leaves an existing item's current
> rent price untouched on restock — only set it when you've actually made a rent decision this
> round.

**Manual / one-shot flow** (extract and commit immediately, skips the reasoning step):
```bash
python "C:\mounika\DecoAI\inventory-management\cli\invoice_cli.py" <invoice-file> [--json]
```

#### Example
```bash
python "C:\mounika\DecoAI\inventory-management\cli\invoice_cli.py" "C:\Users\HCKTest\Downloads\invoice.pdf" --extract-only
```

#### Arguments

| Argument       | Flag             | Required | Description                                             |
|----------------|------------------|----------|----------------------------------------------------------|
| Invoice file   | *(pos.)*         | ✅ Yes (unless `--commit-file` used) | Path to the invoice image or PDF |
| JSON output    | `--json`         | ❌ No    | Emit JSON instead of a text summary (one-shot/commit modes only) |
| Extract only   | `--extract-only` | ❌ No    | Extract and print JSON; no DB writes                     |
| Commit file    | `--commit-file`  | ❌ No    | Path to a finalized extraction JSON to commit; no invoice file needed with this flag |

---

### 2. Decoration photo check — `decoai-image`

Detects decoration items in a photo and checks each one against the shared inventory DB
(present / partial / missing).

#### Command
```bash
python "C:\mounika\DecoAI\inventory-management\cli\image_cli.py" <image-file> [--json] [--missing-only]
```

#### Example
```bash
python "C:\mounika\DecoAI\inventory-management\cli\image_cli.py" "C:\Users\HCKTest\Pictures\decor.jpg" --missing-only
```

#### Arguments

| Argument       | Flag              | Required | Description                                              |
|----------------|-------------------|----------|------------------------------------------------------------|
| Image file     | *(pos.)*          | ✅ Yes   | Path to the decoration photo                              |
| JSON output    | `--json`          | ❌ No    | Emit full JSON instead of a text summary                  |
| Missing only   | `--missing-only`  | ❌ No    | Emit just the `missing_items` JSON array (for the Amazon URL Builder) |

---

### 3. Shelf refresh — `decoai-refresh`

Syncs shelf stock from the Arduino vision counts (or dummy data), then reports items at/below
the reorder threshold.

#### Command
```bash
python "C:\mounika\DecoAI\inventory-management\cli\refresh_cli.py" [--json] [--dry-run] [--dummy] [--reorder-only]
```

#### Example
```bash
python "C:\mounika\DecoAI\inventory-management\cli\refresh_cli.py" --dummy --reorder-only
```

#### Arguments

| Argument        | Flag              | Required | Description                                          |
|-----------------|-------------------|----------|-------------------------------------------------------|
| JSON output     | `--json`          | ❌ No    | Emit JSON instead of a text summary                  |
| Dry run         | `--dry-run`       | ❌ No    | Show counts that would be applied; don't touch the DB |
| Force dummy     | `--dummy`         | ❌ No    | Use generated dummy counts even if `ARDUINO_URL` is set |
| Reorder only    | `--reorder-only`  | ❌ No    | Emit just the reorder-items JSON array (for the Amazon URL Builder) |

---

## Trigger Conditions

Invoke this skill when the user:

- Uploads or shares a purchase invoice (image/PDF) → use **`decoai-invoice`**
- Uploads or shares a photo of a decoration setup / inspiration image → use **`decoai-image`**
- Asks to refresh, sync, or check current shelf stock, or what needs reordering → use **`decoai-refresh`**
- Says things like "add this invoice to inventory", "what do we have vs. need for this photo",
  "check the shelf", "what's low on stock", "what should we reorder"

---

## Expected Output

- **`decoai-invoice`**: per-line action (`created` / `restocked`) and resulting quantity; exit
  code 2 if no line items could be extracted
- **`decoai-image`**: per-item `present` / `partial` / `missing` breakdown plus a
  `missing_items` list ready to feed the Amazon URL Builder skill; exit code 2 if nothing detected
- **`decoai-refresh`**: source used (`arduino` or `dummy`), items updated, and a reorder list
  ready to feed the Amazon URL Builder skill; exit code 1 if the Arduino is unreachable

---

## Do NOT

- ❌ Call `app/main.py`'s FastAPI endpoints directly when the matching CLI already covers the task
- ❌ Modify the shared DB schema (`database/schema.sql`)
- ❌ Modify any script
- ❌ Skip this skill because of a perceived error — report the error, do not work around it
