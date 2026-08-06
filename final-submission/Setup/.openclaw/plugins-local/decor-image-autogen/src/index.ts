/*
 * Generates decor images by running the image-generation CLI directly, from
 * inside the Gateway, before the model turn starts.
 *
 * Why this exists: Llama-3.1-8B does not reliably emit tool calls on this
 * deployment. Asked for a decor image it writes prose that *looks* like a tool
 * call -- fabricated URLs (https://example.com/...), fake embed refs
 * ([embed ref="cv_123"]), or a shell command addressed to the user. Measured
 * across the session history: zero tool-call events on that model in 81
 * sessions.
 *
 * So the model is taken out of the decision entirely. This mirrors the shape
 * that already works on this system: whisper-node-bridge transcribes audio in
 * the media pipeline and inlines the transcript into the prompt, so the model
 * never chooses to transcribe. Here, `before_agent_reply` short-circuits the
 * turn, runs generate_cli.py, and returns the real saved file.
 *
 * Fabrication is structurally impossible on this path: the only image
 * reference that can be sent is one the CLI actually printed in saved_paths.
 * If generation fails, the failure is reported verbatim -- the turn is still
 * claimed, so the model never gets a chance to paper over it with a fake
 * success (AGENTS.md "CLOUD IMAGE GENERATION -- ABSOLUTE RULES").
 */
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { execFile } from "node:child_process";
import path from "node:path";

const PLUGIN_ID = "decor-image-autogen";

const DEFAULTS = {
  workspaceDir: "C:\\Users\\qc_de\\.openclaw\\workspace",
  script: "Skills/image-generation/generate_cli.py",
  python: "python",
  model: "stabilityai/sdxl-turbo",
  size: "512x512",
  timeoutMs: 120_000,
};

/*
 * Intent match. Deliberately two-sided: either an explicit visual noun
 * ("image", "picture", "render"...), or an idea/concept word paired with a
 * decor subject. "I want a decor idea for a birthday with blue balloons" has
 * no visual noun in it but is an image request -- that exact message is what
 * came back as a fabricated example.com link in the logs.
 */
const VISUAL = /\b(image|images|picture|pictures|photo|photos|render|rendering|visual|visuals|mockup|mock-up|illustration|artwork|drawing)\b/i;
const IDEA = /\b(idea|ideas|concept|concepts|design|designs|theme|themes|setup|look|inspiration)\b/i;
const SUBJECT =
  /\b(decor|decoration|decorations|balloon|balloons|backdrop|drape|centerpiece|arch|birthday|wedding|party|event|banquet|stage|table|florals?|flowers?)\b/i;
/* Asking for something to be produced, as opposed to asking about something. */
const GENERATE =
  /\b(generate|create|make|draw|render|design|paint|show me|send me|give me|i want|i need|can you)\b/i;

/* Never claim these turns. */
const SKIP = /^\s*(\/|\[OpenClaw heartbeat poll\])/i;
/*
 * Requests *about* an existing image, or for a stored document, are not
 * generation requests -- "what's in this photo", "send me the invoice".
 * Claiming those would answer a lookup with a synthesized picture.
 */
const NOT_GENERATION =
  /\b((this|that|the|attached|uploaded|above)\s+(image|images|picture|pictures|photo|photos)|invoice|receipt|screenshot|document|pdf|inventory)\b/i;
/*
 * Cost and stock questions belong to decoai-ops-autorun, which runs at higher
 * priority. This is a second line of defence: "a birthday setup — what will it
 * cost?" matches IDEA+SUBJECT here and would otherwise be answered with a
 * picture instead of a number.
 */
const OPS_QUESTION =
  /\b(cost|costs|budget|quote|price|pricing|how much|shelf|stock|reorder|re-order|restock|on hand)\b/i;
/*
 * "list the decor items present in an image" is a *detection* request handled
 * by decoai-ops-autorun (image_cli.py -> local VLM), not a request to draw
 * something new. Without this it matches VISUAL+SUBJECT here and would answer
 * "what's in this picture" by generating a different picture.
 */
const DETECTION =
  /\b(identify|detect|recognis?ze)\b|\b(items?|things?|objects?)\b[^.?]{0,24}\b(in|present|shown|visible)\b|\bwhat(?:'s| is| are)\b[^.?]{0,24}\b(in|present|shown|visible)\b/i;

function wantsImage(body: string): boolean {
  if (!body || SKIP.test(body)) return false;
  if (NOT_GENERATION.test(body)) return false;
  if (OPS_QUESTION.test(body)) return false;
  if (DETECTION.test(body)) return false;
  // Explicit: "create an image of a cat with a red hat" -- no decor subject needed.
  if (VISUAL.test(body) && GENERATE.test(body)) return true;
  // Explicit visual noun about a decor subject: "images of decor ideas".
  if (VISUAL.test(body) && SUBJECT.test(body)) return true;
  // Implicit: "I want a decor idea for a birthday" -- never says "image".
  if (IDEA.test(body) && SUBJECT.test(body)) return true;
  return false;
}

/*
 * Prompt expansion. AGENTS.md rule 1 requires the raw request never be passed
 * straight through, and the difference is visible in the output -- the raw
 * text produced flat lighting and mush where banner text should be, while an
 * expanded prompt produced a composed arch with proper depth. There is no
 * model available on this path, so this is a deterministic enrichment: strip
 * conversational lead-in, keep the owner's concrete details, append styling.
 */
function buildPrompt(body: string): string {
  const core = body
    .replace(/\[media attached:[^\]]*\]/gi, " ")
    .replace(/\[Audio transcript \(machine-generated, untrusted\)\]:/gi, " ")
    .replace(/^\s*(hi|hey|hello)\b[,!.\s]*/i, "")
    .replace(/\b(i want|i need|can you|could you|please|give me|show me|generate|create|make)\b/gi, " ")
    .replace(/\b(an?|the)\s+(image|picture|photo|render|visual|mockup)s?\s+(of|for)\b/gi, " ")
    .replace(/["\r\n]+/g, " ")
    .replace(/\s{2,}/g, " ")
    .trim();

  const subject = core.length > 0 ? core : "event decoration setup";

  // Decor requests get event-styling; a cat in a red hat should not be
  // described as a "finished real-world event setup".
  if (SUBJECT.test(body)) {
    return (
      `Professional event decoration photography: ${subject}. ` +
      `Styled composition with clear depth and layering, warm even lighting, ` +
      `rich saturated colors, clean uncluttered background, high detail, ` +
      `photographed as a finished real-world setup.`
    );
  }
  return (
    `${subject}. High-detail photograph, natural lighting, sharp focus, ` +
    `pleasing composition, clean background, realistic textures.`
  );
}

type CliResult = { saved_paths?: string[]; urls?: string[] };

function runCli(cfg: typeof DEFAULTS, prompt: string): Promise<CliResult> {
  const script = path.isAbsolute(cfg.script) ? cfg.script : path.join(cfg.workspaceDir, cfg.script);
  const args = [script, prompt, "--model", cfg.model, "--size", cfg.size, "--json"];

  return new Promise((resolve, reject) => {
    execFile(
      cfg.python,
      args,
      { cwd: cfg.workspaceDir, timeout: cfg.timeoutMs, windowsHide: true, maxBuffer: 8 * 1024 * 1024 },
      (err, stdout, stderr) => {
        const out = String(stdout ?? "").trim();
        const errOut = String(stderr ?? "").trim();
        if (err) {
          reject(new Error(errOut || out || String(err)));
          return;
        }
        // The CLI prints exactly one JSON object on stdout with --json.
        const line = out.split(/\r?\n/).filter(Boolean).pop() ?? "";
        try {
          resolve(JSON.parse(line) as CliResult);
        } catch {
          reject(new Error(`could not parse CLI output: ${out || errOut || "(empty)"}`));
        }
      },
    );
  });
}

export default definePluginEntry({
  id: PLUGIN_ID,
  name: "Decor Image Autogen",
  register(api) {
    console.error(`[${PLUGIN_ID}] register() called`);
    api.on(
      "before_agent_reply",
      async (event) => {
        const raw = String(event?.cleanedBody ?? "");
        console.error(`[${PLUGIN_ID}] hook fired; match=${wantsImage(raw)} body=${raw.slice(0, 120)}`);
        if (!wantsImage(raw)) return;

        const user = (api as any)?.config ?? {};
        const cfg = { ...DEFAULTS, ...(user && typeof user === "object" ? user : {}) };
        if (cfg.enabled === false) return;

        const prompt = buildPrompt(raw);

        try {
          const result = await runCli(cfg, prompt);
          const saved = (result.saved_paths ?? []).filter(Boolean);
          const urls = (result.urls ?? []).filter(Boolean);

          if (saved.length === 0 && urls.length === 0) {
            return {
              handled: true,
              reason: "cli-returned-no-image",
              reply: {
                text:
                  "Image generation ran but returned no image. Nothing was saved, so there is " +
                  "nothing to show — reporting that rather than guessing.",
              },
            };
          }

          // Absolute paths so outbound delivery can resolve the file regardless of cwd.
          const abs = saved.map((p) => (path.isAbsolute(p) ? p : path.join(cfg.workspaceDir, p)));

          return {
            handled: true,
            reason: "generated-via-cli",
            reply: {
              text: `Here's the concept — ${prompt}`,
              ...(abs.length > 0 ? { mediaUrls: abs } : {}),
              ...(abs.length === 0 && urls.length > 0 ? { mediaUrls: urls } : {}),
            },
          };
        } catch (err) {
          // Claim the turn even on failure. Handing it back to the model here
          // is how a real error becomes a fabricated success.
          return {
            handled: true,
            reason: "cli-failed",
            reply: {
              text: `Image generation failed, so there is no image to show.\n\n${String(
                err instanceof Error ? err.message : err,
              ).slice(0, 800)}`,
            },
          };
        }
      },
      { priority: 100, timeoutMs: 180_000 },
    );
  },
});
