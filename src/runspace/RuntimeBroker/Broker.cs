using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Subsystem.RuntimeBroker
{
    // Broker — the resident agent (the LOCKED name): the conversational face of the RuntimeBroker (Rb).
    // Owns ONE inference runtime behind the Runtime contract — the home-spun C-API LiteRtRuntime (P/Invoke
    // libLiteRtLm.so). The model + system prompt are the CONTRACT it receives (resolved from Cm by Rb,
    // never held here). Streams a turn as structured AgentDelta events; tools come from the runtime-agnostic
    // ToolCatalog the runtime declares, not the engine's native automaticToolCalling.
    public class Broker : IDisposable
    {
        private readonly Runtime _client;
        private readonly string _unitId;       // the \Capability\Model leaf this broker serves

        // Releases the engine + conversation (model switch / shutdown). Safe to call once; the
        // owner (Rb.Reset) swaps the reference out before disposing.
        public void Dispose() => _client.Dispose();

        // The CONTRACT (model + system prompt) is resolved from the registry by the RuntimeBroker and
        // handed in: no head holds the prompt as its own truth — it lives at \Capability\Prompt\* (seeded
        // from shell/prompts.json) and is resolved live. The runtime self-governs placement (admission/
        // OOM budget) in its own bring-up. unitId names the \Capability\Model served.
        public Broker(Android.Content.Context context, string modelPath, string unitId, string systemInstruction, SamplerSpec? sampler = null)
        {
            _unitId = unitId;
            // The C-API runtime (P/Invoke libLiteRtLm.so) over the home-spun binding. The sampler is the
            // model's generation CONTRACT (resolved from \Capability\Model\<id>), handed to the runtime —
            // never held here.
            _client = new LiteRtRuntime(modelPath, unitId, systemInstruction, context.CacheDir?.AbsolutePath, sampler: sampler);
        }

        // Per-turn native counters (tok/s, TTFT) for the UI — surfaced by the runtime (the C-API LiteRtRuntime).
        public Benchmark? GetBenchmark() => _client.GetBenchmark();
        public string BackendName => _client.BackendName;
        public string UnitId => _unitId;

        // §3/§6: serviceability surface — acquisition and verification consult these.
        public bool IsAlive => _client.IsAlive;
        public RbFault? BringUp() => _client.BringUp();

        // Structured stream — the /agent WS and the Invoke-Agent cmdlet consume this.
        public IAsyncEnumerable<AgentDelta> SendTurnAsync(string text, byte[]? audioData = null, CancellationToken ct = default)
            => _client.StreamTurnAsync(text, audioData != null && audioData.Length > 0 ? audioData : null, ct);

        // Fork an ephemeral side-conversation on the shared engine for a sub-agent run (the web-agent loop):
        // its own system prompt + KV, disposed after, so this resident conversation's KV is never polluted.
        public SideConversation? OpenSideConversation(string? systemPrompt, ToolDescriptor[]? tools = null)
            => _client.OpenSideConversation(systemPrompt, tools);

        // Multimodal structured stream: same path with optional image (and audio) bytes. The runtime folds
        // them into the message content parts; runtimes that don't drive vision degrade to text (the
        // Runtime contract's default).
        public IAsyncEnumerable<AgentDelta> SendTurnAsync(string text, byte[]? audioData, byte[]? imageData, CancellationToken ct = default)
            => _client.StreamTurnAsync(text,
                audioData is { Length: > 0 } ? audioData : null,
                imageData is { Length: > 0 } ? imageData : null, ct);

        // Back-compat plain-text stream (visible answer tokens only) for callers that don't need the
        // structured events (one-shots, ss-ask). Thinking + tool chatter are dropped.
        public async IAsyncEnumerable<string> SendMessageStreamAsync(string text, byte[]? audioData = null, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
        {
            await foreach (var d in SendTurnAsync(text, audioData, ct))
                if (d.Kind == AgentDeltaKind.Token && !string.IsNullOrEmpty(d.Text))
                    yield return d.Text;
        }

        // Plain-text stream with an image (the multimodal one-shot path: Invoke-Agent -ImagePath).
        public async IAsyncEnumerable<string> SendMessageStreamAsync(string text, byte[]? audioData, byte[]? imageData, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
        {
            await foreach (var d in SendTurnAsync(text, audioData, imageData, ct))
                if (d.Kind == AgentDeltaKind.Token && !string.IsNullOrEmpty(d.Text))
                    yield return d.Text;
        }
    }
}
