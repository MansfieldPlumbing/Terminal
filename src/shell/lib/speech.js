/* lib/speech.js — the ONE speech seam (window.Speech): Kokoro TTS in the WebView, registry-gated.
 *
 * The lane is gated on the \Capability\Speech\Kokoro Cm record (the one truth — no UI-owned
 * switch); the engine is the vendored onnxruntime-web + kokoro-js dists (no CDN, ever — see
 * src/shell/vendor/ort/README.md and src/shell/vendor/kokoro/README.md); the model rides the
 * registry-seeded \Capability\Model\kokoro lane at /models/kokoro. Every rung degrades:
 * gate off → silent; dists absent → speechSynthesis; that absent too → resolve(false), one warn.
 *
 *   import '/lib/speech.js';                       // or rely on window.Speech after load
 *   if (await Speech.available()) await Speech.say('Hello.', { voice: 'af_heart', speed: 1.0 });
 *   Speech.stop();                                 // cancel-safe: aborts the chunk loop + source
 *
 * Po doctrine: everything is lazy (gate query, probes, imports, AudioContext) and nothing runs at
 * idle — no timers, the AudioContext is suspended whenever no utterance is live.
 */

import { executeCommand } from '/lib/api.js';

const ORT_URL    = '/vendor/ort/ort.min.js';
const KOKORO_URL = '/vendor/kokoro/kokoro.js';
const MODEL_URL  = '/models/kokoro';
const SAMPLE_RATE = 24000;                          // kokoro emits 24kHz mono float PCM
const DEFAULT_VOICE = 'af_heart';

// Structured registry query — composed here, nothing user-supplied is ever spliced in.
const GATE_CMD = 'Get-Capability | Where-Object Path -eq "\\Capability\\Speech\\Kokoro" | Select-Object -ExpandProperty Enabled | ConvertTo-Json';

const S = {
  gateEnabled: false,
  probed: false,        // vendored-dist probe done (probe result is per-page-load)
  libsPresent: false,
  engine: null,         // { tts } once the kokoro pipeline is up
  engineFailed: false,
  engineInit: null,     // in-flight engine init (single-flight)
  initing: null,        // in-flight gate/probe init (single-flight)
  ctx: null,            // AudioContext — created lazily inside say(), suspended at idle
  run: null,            // the live utterance control block
};

const warned = new Set();
function warnOnce(msg) {
  if (warned.has(msg)) return;
  warned.add(msg);
  console.warn('[speech] ' + msg);                  // degrade-and-record, never throw
}

async function queryGate() {
  // /api/exec appends its own ConvertTo-Json server-side, so Enabled may arrive double-encoded
  // (boolean true, or the strings "true"/"True"); an absent record yields {} — gated off.
  try {
    const v = await executeCommand(GATE_CMD);
    return v === true || v === 'true' || v === 'True';
  } catch (e) {
    return false;                                   // no backend = no speech lane
  }
}

// The projection server answers a static miss with an EMPTY 200 (the no-404 rule), so presence
// is a content check, never a status check. HEAD first (cheap when Content-Length is known),
// full GET as the fallback — the bytes are cache-warm for the dynamic import that follows.
async function present(url) {
  try {
    const r = await fetch(url, { method: 'HEAD' });
    if (r.ok) {
      const len = r.headers.get('content-length');
      if (len !== null) return parseInt(len, 10) > 0;
    }
  } catch (e) { /* HEAD not served — measure via GET */ }
  try {
    const r = await fetch(url);
    if (!r.ok) return false;
    return (await r.arrayBuffer()).byteLength > 0;
  } catch (e) {
    return false;
  }
}

function init() {
  // An enabled gate is settled for the page; a disabled one re-asks the registry on the next
  // call (event-driven — the record stays the live truth without any polling timer).
  if (S.gateEnabled && S.probed) return Promise.resolve();
  if (!S.initing) {
    S.initing = (async () => {
      S.gateEnabled = await queryGate();
      if (!S.gateEnabled || S.probed) return;
      const [hasOrt, hasKokoro] = await Promise.all([present(ORT_URL), present(KOKORO_URL)]);
      S.libsPresent = hasOrt && hasKokoro;
      S.probed = true;
      if (!S.libsPresent) {
        warnOnce('vendored ort/kokoro dist absent — degrading to speechSynthesis (see src/shell/vendor/*/README.md)');
      }
    })().finally(() => { S.initing = null; });
  }
  return S.initing;
}

function ensureEngine() {
  if (S.engine || S.engineFailed) return Promise.resolve(S.engine);
  if (!S.engineInit) {
    S.engineInit = (async () => {
      try {
        const [ortMod, kkMod] = await Promise.all([import(ORT_URL), import(KOKORO_URL)]);
        // The ort dist is UMD (lands on globalThis.ort); kokoro-js is ESM — take whichever face loaded.
        const ort = (ortMod && ortMod.InferenceSession) ? ortMod
                  : (globalThis.ort || (ortMod && ortMod.default));
        const kk = (kkMod && (kkMod.KokoroTTS || kkMod.default)) || globalThis.kokoro || kkMod;
        const KokoroTTS = kk && (kk.KokoroTTS || (kk.default && kk.default.KokoroTTS));
        if (ort && ort.env && ort.env.wasm) ort.env.wasm.wasmPaths = '/vendor/ort/';   // .wasm sidecars live beside the dist

        // Model bytes from the registry-seeded lane; the HTTP mount may not exist yet — a miss
        // is an empty 200, not a throw.
        let modelBytes = null;
        try {
          const r = await fetch(MODEL_URL);
          if (r.ok) {
            const b = await r.arrayBuffer();
            if (b.byteLength > 0) modelBytes = new Uint8Array(b);
          }
        } catch (e) { /* lane not mounted — fall to the next rung */ }

        // kokoro-js owns phonemization + voice styles (the real moat — never hand-roll G2P).
        // Probe the dist's faces in order; each rung is optional, the ladder ends at web speech.
        let tts = null;
        if (KokoroTTS) {
          if (modelBytes && ort && ort.InferenceSession && typeof KokoroTTS.from_session === 'function') {
            const session = await ort.InferenceSession.create(modelBytes, { executionProviders: ['wasm'] });
            tts = await KokoroTTS.from_session(session);
          } else if (typeof KokoroTTS.from_pretrained === 'function') {
            tts = await KokoroTTS.from_pretrained(MODEL_URL, { dtype: 'fp32', device: 'wasm' });
          }
        }
        if (tts && typeof tts.generate === 'function') {
          S.engine = { tts };
        } else {
          S.engineFailed = true;
          warnOnce('kokoro dist loaded but no usable pipeline — degrading to speechSynthesis');
        }
      } catch (e) {
        S.engineFailed = true;
        warnOnce('kokoro init failed — degrading to speechSynthesis: ' + (e && e.message));
      } finally {
        S.engineInit = null;
      }
      return S.engine;
    })();
  }
  return S.engineInit;
}

function ensureCtx() {
  if (!S.ctx) S.ctx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: SAMPLE_RATE });
  return S.ctx;
}

// Po: nothing runs at idle — park the audio thread whenever no utterance is live.
function idle() {
  if (!S.run && S.ctx && S.ctx.state === 'running') {
    try { S.ctx.suspend(); } catch (e) { /* already closing */ }
  }
}

function chunkSentences(text) {
  const parts = String(text).match(/[^.!?]+[.!?]+|[^.!?]+$/g) || [];
  return parts.map((s) => s.trim()).filter(Boolean);
}

function playPcm(ctx, run, pcm, rate) {
  return new Promise((resolve) => {
    const buf = ctx.createBuffer(1, pcm.length, rate || SAMPLE_RATE);
    buf.getChannelData(0).set(pcm);
    const src = ctx.createBufferSource();
    src.buffer = buf;
    src.connect(ctx.destination);
    run.source = src;
    src.onended = () => { if (run.source === src) run.source = null; resolve(); };
    src.start();                                    // stop() calls src.stop(0) → onended → resolve
  });
}

async function sayKokoro(engine, run, text, opts) {
  const ctx = ensureCtx();
  if (ctx.state !== 'running') {
    try { await ctx.resume(); } catch (e) { /* gesture-gated — playback may stay silent */ }
  }
  const chunks = chunkSentences(text);
  let spoke = false;
  for (let i = 0; i < chunks.length; i++) {
    if (run.cancelled) break;
    let pcm = null, rate = SAMPLE_RATE;
    try {
      const out = await engine.tts.generate(chunks[i], {
        voice: opts.voice || DEFAULT_VOICE,
        speed: opts.speed || 1.0,
      });
      const audio = out instanceof Float32Array ? out : (out && out.audio);
      pcm = audio instanceof Float32Array ? audio : null;
      rate = (out && out.sampling_rate) || SAMPLE_RATE;
    } catch (e) {
      // Synth died mid-utterance: retire the engine and voice the REMAINDER on the fallback.
      warnOnce('kokoro synth failed — degrading to speechSynthesis: ' + (e && e.message));
      S.engine = null;
      S.engineFailed = true;
      return sayWebSpeech(run, chunks.slice(i).join(' '), opts);
    }
    if (!pcm || run.cancelled) continue;
    await playPcm(ctx, run, pcm, rate);
    spoke = true;
  }
  return spoke && !run.cancelled;
}

function sayWebSpeech(run, text, opts) {
  const synth = window.speechSynthesis || window.webkitSpeechSynthesis;
  if (!synth || typeof SpeechSynthesisUtterance === 'undefined') {
    warnOnce('no vendored kokoro and no speechSynthesis — speech unavailable');
    return Promise.resolve(false);
  }
  if (run.cancelled) return Promise.resolve(false);
  return new Promise((resolve) => {
    const u = new SpeechSynthesisUtterance(text);
    if (opts.speed) u.rate = opts.speed;
    run.webResolve = resolve;                       // stop() resolves(false) — onend never fires on cancel
    u.onend = () => { run.webResolve = null; resolve(true); };
    u.onerror = () => { run.webResolve = null; resolve(false); };
    try { synth.cancel(); } catch (e) { /* stale queue */ }
    synth.speak(u);
  });
}

async function available() {
  await init();
  return !!(S.gateEnabled && S.libsPresent);        // honest about the Kokoro lane; say() still degrades
}

async function say(text, opts = {}) {
  const t = (text == null ? '' : String(text)).trim();
  if (!t) return false;
  await init();
  if (!S.gateEnabled) {
    warnOnce('\\Capability\\Speech\\Kokoro is disabled — speech lane off');
    return false;
  }
  stop();                                           // one voice: a new say() preempts the current one
  const run = { cancelled: false, source: null, webResolve: null };
  S.run = run;
  try {
    if (S.libsPresent) {
      const engine = await ensureEngine();
      if (engine && !run.cancelled) return await sayKokoro(engine, run, t, opts);
    }
    return await sayWebSpeech(run, t, opts);
  } finally {
    if (S.run === run) S.run = null;
    idle();
  }
}

function stop() {
  const run = S.run;
  if (!run) return;
  run.cancelled = true;
  if (run.source) {
    try { run.source.stop(0); } catch (e) { /* already ended */ }
    run.source = null;
  }
  const synth = window.speechSynthesis || window.webkitSpeechSynthesis;
  if (synth) { try { synth.cancel(); } catch (e) { /* not speaking */ } }
  if (run.webResolve) { const r = run.webResolve; run.webResolve = null; r(false); }
  S.run = null;
  idle();
}

export const Speech = { available, say, stop };
window.Speech = Speech;
