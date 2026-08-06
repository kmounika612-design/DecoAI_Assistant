/*
 * Runs the inventory-management and cost-estimation CLIs from inside the
 * Gateway, before the model turn, for the questions whose answers live in the
 * shared DecoAI SQLite DB.
 *
 * Why: on Llama-3.1-8B this deployment produces no tool calls (zero across 81
 * sessions), so DB-backed questions get answered from the model's imagination
 * instead. Observed in the logs: a full event plan with an invented
 * "Estimated Cost: $150", and a budget breakdown for a $2,500 event, neither
 * of which ever touched estimate_cli.py. AGENTS.md forbids exactly this, and
 * the model ignored it -- so the decision is taken away from the model.
 *
 * Scope, deliberately limited to what is genuinely deterministic:
 *   - shelf refresh / reorder  -> refresh_cli.py   (no arguments -- exact)
 *   - decoration photo vs stock -> image_cli.py    (path comes from the message)
 *   - cost estimate             -> estimate_cli.py (items parsed from the text)
 *
 * NOT handled here: invoice intake. invoice_cli.py's flow requires deciding
 * reusability and a sensible per-rental price for every line
 * (AGENTS.md INVENTORY MANAGEMENT step 2). That is judgment, not extraction.
 * A plugin could only skip it or invent numbers, and inventing numbers is the
 * bug this plugin exists to remove -- so invoices still go to the model.
 */
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { execFile } from "node:child_process";
import path from "node:path";

const PLUGIN_ID = "decoai-ops-autorun";

const DEFAULTS = {
  workspaceDir: "C:\\Users\\qc_de\\.openclaw\\workspace",
  python: "python",
  timeoutMs: 120_000,
};

const CLI = {
  refresh: "Skills/inventory-management/cli/refresh_cli.py",
  photo: "Skills/inventory-management/cli/image_cli.py",
  estimate: "Skills/cost-estimation/cli/estimate_cli.py",
  dump: "Skills/database/db_dump.py",
  invoice: "Skills/inventory-management/cli/invoice_cli.py",
};

const ENV_FILE = "Skills/.env";

/*
 * db_dump.py is the one script here that does NOT call load_dotenv, so without
 * an explicit DECOAI_DB_PATH it falls back to db.py:31 (HERE/decoai.sqlite) and
 * silently creates a second, empty database next to the module. Read the shared
 * .env ourselves and pass the path through.
 */
/*
 * Resolve which image "this image" means.
 *
 * before_agent_reply's cleanedBody does NOT carry the "[media attached: ...]"
 * marker -- confirmed in the gateway log: "Tell me all the decor items present
 * in this image" arrives with no path in it at all. So the file has to be found
 * on disk. Two places matter, and the most recent wins:
 *
 *   - workspace/media/inbound/openclaw-staged-*  (the owner uploaded a photo)
 *   - Skills/image-generation/output             (we just generated one, which
 *     is what "this image" meant at 03:35 in the log -- the request followed a
 *     generation, not an upload)
 *
 * Bounded by MAX_AGE_MS so a question asked cold doesn't get answered about
 * some picture from last week. The reply always names the file it read, so the
 * choice is visible rather than mysterious.
 */
const IMAGE_EXT = /\.(png|jpe?g|webp)$/i;
const MAX_AGE_MS = 60 * 60 * 1000;

function newestImageUnder(root: string, fs: typeof import("node:fs")): { file: string; mtime: number } | undefined {
  let best: { file: string; mtime: number } | undefined;
  const walk = (dir: string, depth: number) => {
    if (depth > 3) return;
    let entries: import("node:fs").Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full, depth + 1);
      else if (IMAGE_EXT.test(e.name)) {
        try {
          const m = fs.statSync(full).mtimeMs;
          if (!best || m > best.mtime) best = { file: full, mtime: m };
        } catch { /* skip */ }
      }
    }
  };
  walk(root, 0);
  return best;
}

function findRecentImage(workspaceDir: string): string | undefined {
  const fs = require("node:fs") as typeof import("node:fs");
  const roots = [
    path.join(workspaceDir, "media", "inbound"),
    path.join(workspaceDir, "Skills", "image-generation", "output"),
  ];
  let best: { file: string; mtime: number } | undefined;
  for (const r of roots) {
    const c = newestImageUnder(r, fs);
    if (c && (!best || c.mtime > best.mtime)) best = c;
  }
  if (!best) return undefined;
  if (Date.now() - best.mtime > MAX_AGE_MS) return undefined;
  return best.file;
}

function readEnvFile(workspaceDir: string): Record<string, string> {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const fs = require("node:fs") as typeof import("node:fs");
    const raw = fs.readFileSync(path.join(workspaceDir, ENV_FILE), "utf8");
    const out: Record<string, string> = {};
    for (const line of raw.split(/\r?\n/)) {
      const t = line.trim();
      if (!t || t.startsWith("#")) continue;
      const i = t.indexOf("=");
      if (i <= 0) continue;
      out[t.slice(0, i).trim()] = t.slice(i + 1).trim().replace(/^["']|["']$/g, "");
    }
    return out;
  } catch {
    return {};
  }
}

const SKIP = /^\s*(\/|\[OpenClaw heartbeat poll\])/i;

/*
 * Read-only "what is in the DB" -- answered by db_dump.py.
 * Kept separate from REFRESH below because refresh_cli.py *writes*: with no
 * ARDUINO_URL it applies dummy_counts() to the items table. Answering a
 * read-only question by mutating the database would be a real bug, so any
 * phrasing that is merely asking gets routed here instead.
 */
const LIST =
  /\b(list|show|display|what(?:'s| is| are)?)\b[^?]{0,40}\b(item|items|inventory|stock|database|db|shelf)\b|\b(inventory|stock)\s+(list|report|contents)\b|\bwhat do we have\b|\bwhat have we got\b|\bon hand\b|\bin stock\b/i;

/* Genuinely asking to re-poll hardware or find reorder candidates. */
const REFRESH =
  /\b(refresh|re-?sync|sync|poll|update)\b[^?]{0,30}\b(shelf|stock|count|counts|inventory)\b|\b(reorder|re-order|restock)\b|\b(low on|running low)\b/i;

/* Cost, budget, quotes -- estimate_cli.py. */
const COST =
  /\b(cost|costs|budget|quote|price|pricing|how much|expensive|afford|spend)\b/i;

/*
 * Reading a shared photo -- image_cli.py detects decor items via the local
 * Qwen2.5-VL on GenieX and checks each against the DB. Covers both framings:
 * "check this against stock" and "what items are in this picture".
 */
const PHOTO_CHECK =
  /\b(check|compare|match|against|have vs|what.{0,12}need|missing|list|identify|detect|recognis?ze|what(?:'s| is| are)?\b[^?]{0,20}\b(?:in|present|shown|visible)|items?\b|decor)\b/i;

const MEDIA_PATH = /\[media attached:\s*([^\]]+?)\s*\((image\/[a-z+]+)\)\]/i;

/*
 * The question has to actually be about a picture. Without this, "list the
 * items" (meaning the database) and "what's in this image" are indistinguishable
 * -- and the log shows the former winning, so asking about an image dumped the
 * inventory table instead.
 */
const REFERS_TO_IMAGE =
  /\b(image|images|picture|pictures|photo|photos|photograph|pic|pics|render|snapshot)\b/i;

/* Invoice intake. Accepts a PDF as well as an image. */
const INVOICE = /\b(invoice|bill|receipt)\b/i;
const INTAKE = /\b(upload|add|save|record|import|enter|load|put)\b|\bto (?:the )?(?:database|db|inventory)\b/i;
const ANY_MEDIA =
  /\[media attached:\s*([^\]]+?)\s*\((?:application\/pdf|image\/[a-z+]+)\)\]/i;
/* A path typed straight into the message, quoted or bare. */
const PATH_LITERAL = /["']?((?:[A-Za-z]:\\|\\\\)[^"'\r\n]+?\.(?:pdf|png|jpe?g|webp))["']?/i;

function findInvoicePath(body: string): string | undefined {
  const m = body.match(ANY_MEDIA);
  if (m) return m[1];
  const p = body.match(PATH_LITERAL);
  if (p) return p[1];
  return undefined;
}

/*
 * Pull "20 blue balloons", "3 fairy lights", "10 chairs" out of free text.
 * Only quantified items count: without a number there is no quantity to
 * estimate against, and guessing one would reintroduce invented figures.
 */
const ITEM = /(\d+)\s+([a-zA-Z][a-zA-Z' -]{1,40}?)(?=\s*(?:,|;|\.|\band\b|\bwith\b|\bfor\b|$))/g;
const COLORS =
  /\b(red|blue|green|yellow|orange|purple|pink|white|black|gold|golden|silver|teal|navy|ivory|cream|rose|peach|lavender)\b/i;

type Item = { item_name: string; color?: string; quantity: number };

function parseItems(body: string): Item[] {
  const items: Item[] = [];
  ITEM.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = ITEM.exec(body)) !== null) {
    const qty = Number.parseInt(m[1], 10);
    let name = m[2].trim().toLowerCase();
    if (!Number.isFinite(qty) || qty <= 0 || name.length < 3) continue;
    // Drop leading filler that survives the split ("more blue balloons").
    name = name.replace(/^(more|extra|additional|some|the|a|an)\s+/i, "").trim();
    // The clause often runs into the ask ("3 fairy lights cost"); strip the
    // trailing intent words so "fairy lights cost" doesn't reach the DB as an
    // item name and come back as a spurious `missing`.
    name = name
      .replace(/\s+(cost|costs|costing|budget|price|priced|pricing|estimate|total|please|overall|roughly|approx|approximately)$/i, "")
      .trim();
    if (name.length < 3) continue;
    const c = name.match(COLORS);
    const color = c ? c[0].toLowerCase() : undefined;
    const item_name = name.replace(COLORS, "").replace(/\s{2,}/g, " ").trim() || name;
    items.push({ item_name, ...(color ? { color } : {}), quantity: qty });
  }
  return items;
}

function runPy(
  cfg: typeof DEFAULTS,
  script: string,
  args: string[],
  extraEnv?: Record<string, string>,
): Promise<string> {
  const abs = path.isAbsolute(script) ? script : path.join(cfg.workspaceDir, script);
  return new Promise((resolve, reject) => {
    execFile(
      cfg.python,
      [abs, ...args],
      {
        cwd: cfg.workspaceDir,
        timeout: cfg.timeoutMs,
        windowsHide: true,
        maxBuffer: 8 * 1024 * 1024,
        ...(extraEnv ? { env: { ...process.env, ...extraEnv } } : {}),
      },
      (err, stdout, stderr) => {
        const out = String(stdout ?? "").trim();
        const errOut = String(stderr ?? "").trim();
        if (err) reject(new Error(errOut || out || String(err)));
        else resolve(out);
      },
    );
  });
}

function fence(label: string, body: string): string {
  return `${label}\n\n\`\`\`json\n${body.slice(0, 3000)}\n\`\`\``;
}

/* ---------- readable output ----------------------------------------------
 * These go to the owner in Telegram, so raw JSON is the wrong shape: it buries
 * the two or three numbers that matter in punctuation. Each formatter parses
 * the CLI payload and renders a short bulleted summary, falling back to the
 * JSON fence only when the payload doesn't parse -- a formatter must never
 * swallow output it didn't understand.
 * ------------------------------------------------------------------------ */

const money = (n: unknown): string =>
  typeof n === "number" && Number.isFinite(n) ? `$${n.toFixed(2)}` : "—";

function parseOr<T>(raw: string): T | undefined {
  try {
    return JSON.parse(raw) as T;
  } catch {
    return undefined;
  }
}

function bullets(lines: string[]): string {
  return lines.map((l) => `• ${l}`).join("\n");
}

function formatInventory(raw: string): string | undefined {
  const rows = parseOr<any[]>(raw);
  if (!Array.isArray(rows)) return undefined;
  if (rows.length === 0) return undefined; // caller handles the empty case
  const items = rows.map((r) => {
    const colour = r.color ? ` (${r.color})` : "";
    const rent = r.rent_ea ? ` · rents ${money(r.rent_ea)}` : "";
    return `*${r.item_name}*${colour} — ${r.quantity} in stock · ${money(r.cost_ea)} each${rent}`;
  });
  const value = rows.reduce(
    (s, r) => s + (Number(r.cost_ea) || 0) * (Number(r.quantity) || 0), 0);
  return `*Inventory — ${rows.length} item${rows.length === 1 ? "" : "s"}*\n\n${bullets(items)}\n\nStock value: ${money(value)}`;
}

function formatPhoto(raw: string, file: string): string | undefined {
  const p = parseOr<any>(raw);
  if (!p || !Array.isArray(p.results)) return undefined;
  const mark = (s: string) => (s === "present" ? "✅" : s === "partial" ? "⚠️" : "❌");
  const items = p.results.map((r: any) => {
    const colour = r.color ? ` (${r.color})` : "";
    const short = r.shortfall > 0 ? ` · short ${r.shortfall}` : "";
    return `${mark(r.status)} *${r.item_name}*${colour} — ${r.detected_quantity} in the photo, ${r.in_stock} in stock${short}`;
  });
  const missing = Array.isArray(p.missing_items) ? p.missing_items : [];
  const tail = missing.length
    ? `\n\n*Need to buy:* ` +
      missing.map((m: any) => `${m.quantity}× ${m.item_name}${m.color ? ` (${m.color})` : ""}`).join(", ")
    : "\n\nEverything detected is covered by current stock.";
  return `*${file}* — ${p.items_detected} item${p.items_detected === 1 ? "" : "s"} detected\n\n${bullets(items)}${tail}`;
}

function formatEstimate(raw: string, label: string): string | undefined {
  const p = parseOr<any>(raw);
  if (!p || !Array.isArray(p.lines)) return undefined;
  const items = p.lines.map((l: any) => {
    const colour = l.color ? ` (${l.color})` : "";
    const priced = l.price_source === "db";
    const cost = priced ? ` → ${money(l.line_cost)}` : " → not priced";
    return `*${l.item_name}*${colour} — need ${l.needed}, have ${l.in_stock}, short ${l.missing}${cost}`;
  });
  const unpriced = p.lines.filter((l: any) => l.price_source !== "db");
  const tail = unpriced.length
    ? `\n\n⚠️ No DB price for: ${unpriced.map((l: any) => l.item_name).join(", ")} — excluded from the total.`
    : "";
  return `*Estimate — ${label}*\n\n${bullets(items)}\n\n*Total (DB-priced): ${money(p.total_cost)}*${tail}`;
}

function formatRefresh(raw: string): string | undefined {
  const p = parseOr<any>(raw);
  if (!p || typeof p !== "object") return undefined;
  const reorder = Array.isArray(p.reorder_items) ? p.reorder_items : [];
  const head =
    `*Shelf refresh* — source ${p.source}, ${p.bins_seen} bin${p.bins_seen === 1 ? "" : "s"} read, ` +
    `${p.items_updated} item${p.items_updated === 1 ? "" : "s"} updated`;
  if (reorder.length === 0) return `${head}\n\nNothing is below the reorder threshold.`;
  const items = reorder.map((r: any) =>
    `*${r.item_name}*${r.color ? ` (${r.color})` : ""} — ${r.quantity} left`);
  return `${head}\n\n*Reorder:*\n${bullets(items)}`;
}

function formatInvoice(raw: string, file: string): string | undefined {
  const p = parseOr<any>(raw);
  if (!p || !Array.isArray(p.results)) return undefined;
  const items = p.results.map((r: any) =>
    `*${r.item_name}* — ${r.action}, qty now ${r.quantity}`);
  return `*${file}* — invoice dated ${p.invoice_date ?? "unknown"}, ${p.lines_extracted} line item${p.lines_extracted === 1 ? "" : "s"}\n\n${bullets(items)}`;
}

export default definePluginEntry({
  id: PLUGIN_ID,
  name: "DecoAI Ops Autorun",
  register(api) {
    console.error(`[${PLUGIN_ID}] register() called`);
    api.on(
      "before_agent_reply",
      async (event) => {
        const body = String(event?.cleanedBody ?? "");
        if (!body || SKIP.test(body)) return;

        const user = (api as any)?.config ?? {};
        const cfg = { ...DEFAULTS, ...(user && typeof user === "object" ? user : {}) };
        if ((cfg as any).enabled === false) return;

        const media = body.match(MEDIA_PATH);

        try {
          // 1. Invoice intake. Checked first so an invoice PDF/photo does not
          //    fall into the decoration photo-check below.
          //
          //    Uses invoice_cli.py's one-shot mode, which per its own docstring
          //    (line 11) extracts and commits but "rent_ea is never set". That
          //    matters: the rent decision in AGENTS.md step 2 is judgment, and
          //    a plugin inventing prices is the bug we are removing. Omitting
          //    rent_ea also leaves an existing item's rent untouched on
          //    restock (SKILL.md), so nothing is silently overwritten. The
          //    outstanding decision is surfaced in the reply instead.
          if (INVOICE.test(body) && INTAKE.test(body)) {
            const file = findInvoicePath(body);
            if (!file) {
              return {
                handled: true,
                reason: "invoice-no-path",
                reply: {
                  text:
                    "I can add that invoice to the database, but I need the file — " +
                    "attach it, or give me the full path.",
                },
              };
            }
            /*
             * Extract, then commit. Operator decision: accept the vision
             * model's figures as estimates rather than gate every invoice on
             * manual approval.
             *
             * Two things this deliberately keeps:
             *
             * 1. Retry on malformed JSON. Qwen2.5-VL-7B intermittently emits
             *    JSON that fails to parse (observed: "Expecting ',' delimiter:
             *    line 28"), so --extract-only runs up to EXTRACT_TRIES times
             *    until the payload parses, then commits that exact payload via
             *    --commit-file. One-shot mode would abort the whole intake on
             *    the first bad parse.
             * 2. An accuracy warning on every reply. Measured against
             *    deco_invoice.pdf the model got roughly 30-60% of fields right
             *    across runs -- wrong quantities, unit prices, one invented
             *    colour, "Light Bulbs" renamed to "Golden Bulbs", and the due
             *    date returned as the invoice date. The numbers are estimates
             *    and the reply has to say so, because nothing downstream
             *    re-checks them against the paper invoice.
             */
            const EXTRACT_TRIES = 3;
            let extraction: string | undefined;
            let lastErr = "";
            for (let i = 0; i < EXTRACT_TRIES; i++) {
              try {
                const raw = await runPy(cfg, CLI.invoice, [file, "--extract-only"]);
                const parsed = JSON.parse(raw);
                if (Array.isArray(parsed?.lines) && parsed.lines.length > 0) {
                  extraction = JSON.stringify(parsed);
                  break;
                }
                lastErr = "extraction contained no line items";
              } catch (e) {
                lastErr = String(e instanceof Error ? e.message : e).slice(0, 200);
              }
            }

            if (!extraction) {
              return {
                handled: true,
                reason: "invoice-extract-failed",
                reply: {
                  text:
                    `Couldn't read \`${path.basename(file)}\` after ${EXTRACT_TRIES} attempts, ` +
                    `so nothing was written.\n\n${lastErr}`,
                },
              };
            }

            const fs = require("node:fs") as typeof import("node:fs");
            const os = require("node:os") as typeof import("node:os");
            const tmp = path.join(os.tmpdir(), `decoai-invoice-${Date.now()}.json`);
            fs.writeFileSync(tmp, extraction, "utf8");
            try {
              const out = await runPy(cfg, CLI.invoice, ["--commit-file", tmp, "--json"]);
              console.error(`[${PLUGIN_ID}] invoice committed: ${file}`);
              return {
                handled: true,
                reason: "invoice-committed",
                reply: {
                  text:
                    (formatInvoice(out, path.basename(file)) ??
                      fence(`Committed \`${path.basename(file)}\`:`, out)) +
                    "\n\n_Figures come from the invoice's text layer when it has one; scanned " +
                    "invoices fall back to the vision model and should be spot-checked. " +
                    "`rent_ea` was not set._",
                },
              };
            } finally {
              try { fs.unlinkSync(tmp); } catch { /* best effort */ }
            }
          }

          // 2. Read a photo: detect decor items via the local VLM and check
          //    each against stock. Requires a resolvable image file -- either
          //    named in the message or the most recent one on disk. Without a
          //    file this must NOT fall through to the LIST branch below, which
          //    would answer "what's in this image" with a dump of the database.
          const wantsPhoto = PHOTO_CHECK.test(body) && REFERS_TO_IMAGE.test(body);
          if (media || wantsPhoto) {
            const file = media ? media[1] : findRecentImage(cfg.workspaceDir);
            if (!file) {
              console.error(`[${PLUGIN_ID}] photo-detect: no image found`);
              return {
                handled: true,
                reason: "photo-no-image",
                reply: {
                  text:
                    "I don't have an image to look at — nothing was attached and I can't " +
                    "find a recent one. Send the photo and I'll list what's in it and check " +
                    "each item against inventory.",
                },
              };
            }
            const out = await runPy(cfg, CLI.photo, [file, "--json"]);
            console.error(`[${PLUGIN_ID}] photo-detect ran on ${file}`);
            const pretty = formatPhoto(out, path.basename(file));
            return {
              handled: true,
              reason: "inventory-photo-check",
              reply: {
                text:
                  (pretty ?? fence(`Items detected in \`${path.basename(file)}\`:`, out)) +
                  "\n\n_Names and counts come from the local vision model — approximate._",
              },
            };
          }

          // 2. Read-only listing. Checked before REFRESH so that merely asking
          //    never mutates the table.
          if (LIST.test(body) && !COST.test(body)) {
            const env = readEnvFile(cfg.workspaceDir);
            const out = await runPy(cfg, CLI.dump, ["--json"], {
              ...(env.DECOAI_DB_PATH ? { DECOAI_DB_PATH: env.DECOAI_DB_PATH } : {}),
            });
            console.error(`[${PLUGIN_ID}] db_dump ran`);
            const empty = out.replace(/\s/g, "") === "[]";
            return {
              handled: true,
              reason: "inventory-list",
              reply: {
                text: empty
                  ? "The inventory database is empty — the `items` table has no rows. " +
                    "Nothing has been added yet, so there is no list to show. " +
                    "Upload a purchase invoice to populate it.\n\n" +
                    `DB: \`${env.DECOAI_DB_PATH ?? "(default path)"}\``
                  : (formatInventory(out) ?? fence("Current contents of the inventory DB:", out)),
              },
            };
          }

          // 3. Shelf refresh / reorder. This one WRITES. With no ARDUINO_URL,
          //    refresh_cli.py applies dummy_counts() to the items table, so
          //    running it without hardware would overwrite real quantities with
          //    fabricated ones -- exactly the class of bug this plugin exists
          //    to prevent. Refuse instead.
          if (REFRESH.test(body) && !COST.test(body)) {
            const env = readEnvFile(cfg.workspaceDir);
            if (!env.ARDUINO_URL) {
              console.error(`[${PLUGIN_ID}] refresh refused - no ARDUINO_URL`);
              return {
                handled: true,
                reason: "refresh-no-hardware",
                reply: {
                  text:
                    "I can't refresh shelf counts: `ARDUINO_URL` is empty in `Skills/.env`, " +
                    "so there's no scale to read. Running the refresh anyway would write " +
                    "generated dummy counts over the real quantities, so I've stopped.\n\n" +
                    "Set `ARDUINO_URL` and ask again, or ask for the current item list to " +
                    "see what's actually stored.",
                },
              };
            }
            const out = await runPy(cfg, CLI.refresh, ["--json"]);
            console.error(`[${PLUGIN_ID}] refresh ran`);
            return {
              handled: true,
              reason: "inventory-refresh",
              reply: { text: formatRefresh(out) ?? fence("Live shelf status:", out) },
            };
          }

          // 3. Cost estimate. Only claim when quantified items are present --
          //    otherwise there is nothing real to price.
          if (COST.test(body)) {
            const items = parseItems(body);
            if (items.length === 0) {
              return {
                handled: true,
                reason: "cost-needs-items",
                reply: {
                  text:
                    "I price from the inventory DB, and I need quantities to do that — " +
                    "for example \"20 blue balloons, 3 fairy lights, 6 chairs\". " +
                    "Send the item list with counts and I'll run the real estimate. " +
                    "(I won't guess a budget.)",
                },
              };
            }
            const out = await runPy(cfg, CLI.estimate, [JSON.stringify(items), "--json"]);
            console.error(`[${PLUGIN_ID}] estimate ran for ${items.length} item(s)`);
            return {
              handled: true,
              reason: "cost-estimate",
              reply: {
                text:
                  formatEstimate(
                    out,
                    items
                      .map((i) => `${i.quantity}× ${i.color ? i.color + " " : ""}${i.item_name}`)
                      .join(", "),
                  ) ?? fence("Estimate from the inventory DB:", out),
              },
            };
          }
        } catch (err) {
          // Claim the failure. Handing it back is how a real error becomes an
          // invented answer.
          return {
            handled: true,
            reason: "cli-failed",
            reply: {
              text: `That lookup failed, so I have no figures to report.\n\n${String(
                err instanceof Error ? err.message : err,
              ).slice(0, 800)}`,
            },
          };
        }

        return;
      },
      { priority: 200, timeoutMs: 180_000 },
    );
  },
});
