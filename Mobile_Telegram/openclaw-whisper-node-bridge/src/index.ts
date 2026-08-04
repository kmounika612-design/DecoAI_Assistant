/*
 * Bridges OpenClaw's audio media-understanding pipeline to an on-device
 * Whisper NPU node paired over the Gateway node protocol (docs/gateway/protocol.md).
 *
 * Flow: Telegram voice note -> Gateway downloads it -> media-understanding
 * runner calls transcribeAudio(req) with the raw bytes already in req.buffer
 * -> this plugin transcodes to 16kHz mono PCM16 WAV, base64-encodes it, and
 * calls api.runtime.nodes.invoke({ command: "whisper.transcribe" }) on the
 * paired phone -> the phone's WhisperTelegramNode app runs the QNN-accelerated
 * Whisper-Small model and returns { text } -> that text becomes the transcript
 * (tools.media.audio / {{Transcript}}), same as any other audio provider.
 */
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { spawn } from "node:child_process";

const PLUGIN_ID = "whisper-node-bridge";
// Fallback only - real calls should get req.timeoutMs from the media-
// understanding runner (see tools.media.audio.timeoutSeconds in README.md).
// Raised from the original 60s: the phone's WhisperEngine now runs in
// continuous-transcription mode so a multi-utterance voice note is
// processed in full rather than truncated to the first detected utterance,
// so total wall time scales with clip length, not just with one segment.
const DEFAULT_TIMEOUT_MS = 120_000;
// Upper bound on how much of the overall budget the local ffmpeg transcode
// may consume, so it can never eat the whole timeout and starve the actual
// node.invoke call. A 16kHz mono transcode of a Telegram-length voice note
// is a sub-second-to-low-seconds operation in practice; 10s is generous
// headroom, not an expected duration.
const MAX_TRANSCODE_SHARE_MS = 10_000;


/**
 * Transcode arbitrary compressed audio (Telegram voice notes are OGG/Opus) to
 * 16kHz mono PCM16 WAV via ffmpeg, entirely in-memory (stdin/stdout pipes, no
 * temp files). This must match the format SimpleAudioRecord/WhisperEngine on
 * the phone expects.
 */
function transcodeToWav16kMono(input: Buffer, timeoutMs: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const ffmpeg = spawn("ffmpeg", [
      "-hide_banner",
      "-loglevel",
      "error",
      "-i",
      "pipe:0",
      "-ar",
      "16000",
      "-ac",
      "1",
      "-f",
      "wav",
      "pipe:1",
    ]);

    const stdoutChunks: Buffer[] = [];
    const stderrChunks: Buffer[] = [];
    const timer = setTimeout(() => {
      ffmpeg.kill("SIGKILL");
      reject(new Error(`ffmpeg transcode timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    ffmpeg.stdout.on("data", (chunk: Buffer) => stdoutChunks.push(chunk));
    ffmpeg.stderr.on("data", (chunk: Buffer) => stderrChunks.push(chunk));
    ffmpeg.on("error", (err) => {
      clearTimeout(timer);
      reject(new Error(`failed to spawn ffmpeg: ${err.message}`));
    });
    ffmpeg.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(`ffmpeg exited ${code}: ${Buffer.concat(stderrChunks).toString("utf8")}`));
        return;
      }
      resolve(Buffer.concat(stdoutChunks));
    });

    ffmpeg.stdin.write(input);
    ffmpeg.stdin.end();
  });
}

export default definePluginEntry({
  id: PLUGIN_ID,
  name: "Whisper Node Bridge",
  description:
    "Routes inbound audio transcription to an on-device Whisper NPU node over the Gateway node protocol.",

  register(api) {
    api.registerMediaUnderstandingProvider({
      id: PLUGIN_ID,
      capabilities: ["audio"],

      // No cloud credential is needed; the "auth" is node pairing/allowlist,
      // enforced by the gateway's node command policy on invoke.
      resolveAuth: () => ({
        kind: "none",
        source: "whisper-node-bridge (on-device NPU, no cloud credential)",
      }),

      transcribeAudio: async (req) => {
        const pluginConfig = api.pluginConfig as { nodeId?: string; timeoutMs?: number };
        const nodeId = pluginConfig.nodeId;
        if (!nodeId) {
          throw new Error(
            "whisper-node-bridge: plugins.entries.whisper-node-bridge.config.nodeId is not set",
          );
        }
        // Respect the runner's per-request timeout budget (req.timeoutMs) the
        // same way every other media-understanding provider does; the plugin
        // config value is only a fallback for direct/manual invocation paths.
        const totalTimeoutMs = req.timeoutMs ?? pluginConfig.timeoutMs ?? DEFAULT_TIMEOUT_MS;

        // Split the one overall budget across the two sequential steps
        // instead of giving each step the full budget independently - that
        // would let worst-case total latency run close to 2x the caller's
        // intended timeout.
        const transcodeTimeoutMs = Math.min(MAX_TRANSCODE_SHARE_MS, Math.floor(totalTimeoutMs / 4));
        const invokeTimeoutMs = totalTimeoutMs - transcodeTimeoutMs;

        // Temporary stage timing to find where end-to-end latency actually
        // goes (transcode vs. base64 encode vs. the node round-trip) before
        // optimizing any of them further.
        const t0 = Date.now();
        const wavBuffer = await transcodeToWav16kMono(req.buffer, transcodeTimeoutMs);
        const t1 = Date.now();
        const audioBase64 = wavBuffer.toString("base64");
        const t2 = Date.now();

        const result = await api.runtime.nodes.invoke({
          nodeId,
          command: "whisper.transcribe",
          params: { audioBase64 },
          timeoutMs: invokeTimeoutMs,
        });
        const t3 = Date.now();
        api.logger.info(
          `whisper-node-bridge timing: inputBytes=${req.buffer.length} wavBytes=${wavBuffer.length} ` +
            `transcodeMs=${t1 - t0} base64EncodeMs=${t2 - t1} nodeInvokeMs=${t3 - t2} totalMs=${t3 - t0}`,
        );

        // api.runtime.nodes.invoke() resolves to the gateway's node.invoke
        // response envelope ({ ok, nodeId, command, payload, payloadJSON }),
        // not the node's raw payload - the phone's { text } is nested one
        // level deeper at result.payload.text.
        const text = (result as { payload?: { text?: unknown } } | null | undefined)?.payload?.text;
        if (typeof text !== "string") {
          throw new Error(
            "whisper-node-bridge: node returned an unexpected result shape (expected { text: string })",
          );
        }

        return { text, model: "whisper-small-quantized@8750" };
      },
    });
  },
});
