using System;
using System.Collections.Generic;
using System.Threading;

namespace Subsystem.RuntimeBroker
{
    // The inference-runtime contract every backend implements: one Runtime per inference exec —
    // LiteRtRuntime (LiteRT-LM, C API), OnnxRuntime, GgmlRuntime — each brokered behind the
    // RuntimeBroker (Rb). Rb routes a request to the active unit's runtime, authorizes it, and owns
    // its lifecycle while holding zero placement/tuning knobs of its own; the runtime self-governs its
    // placement (admission / OOM budget) in BringUp and streams a turn as structured AgentDelta events.
    public interface Runtime : IDisposable
    {
        // Self-governed bring-up: plan admission, construct the engine + conversation, verify liveness.
        // Returns the typed fault, or null when the runtime is serviceable. Idempotent.
        RbFault? BringUp();

        // Stream one turn as structured events (visible tokens, the thinking channel, tool activity).
        IAsyncEnumerable<AgentDelta> StreamTurnAsync(string prompt, byte[]? audioBytes, CancellationToken ct = default);

        // Multimodal turn: the same structured stream with optional encoded image bytes (JPEG/PNG) fed as
        // a content part. Default-implemented to degrade to the text/audio path so a runtime that does not
        // (yet) drive vision — the parked Windows LiteRT, the deprecated JNI client — stays serviceable
        // unchanged; the C-API LiteRtRuntime overrides it. Gemma 4 is natively multimodal, so the engine's
        // ModelDataProcessor preprocesses the image inline — no separate encoder hop.
        IAsyncEnumerable<AgentDelta> StreamTurnAsync(string prompt, byte[]? audioBytes, byte[]? imageBytes, CancellationToken ct = default)
            => StreamTurnAsync(prompt, audioBytes, ct);

        // Serviceability surface — acquisition and verification consult these before dispatch.
        bool IsAlive { get; }
        string BackendName { get; }

        // Optional per-turn native counters (tok/s, TTFT) for the UI / a Measure cmdlet. Default null so a
        // runtime that surfaces none stays serviceable; the C-API LiteRtRuntime overrides it.
        Benchmark? GetBenchmark() => null;

        // Open an ephemeral side-conversation on the SAME engine (shared weights) with its OWN system
        // prompt, tools, and KV — the "Conversation = per-agent unit" discipline for a sub-agent run whose
        // context must NOT persist into the resident conversation. The fork is disposed after the run, so
        // the resident KV is untouched. Default: none (degrade to null) so a runtime without a second-
        // conversation path stays serviceable; the C-API LiteRtRuntime overrides it.
        SideConversation? OpenSideConversation(string? systemPrompt, ToolDescriptor[]? tools) => null;
    }

    // A conversation forked onto a live runtime's existing engine: shared weights, its OWN KV, disposed
    // after a sub-agent run. Streaming + cancellation mirror the runtime's main turn path; Dispose frees
    // this conversation's KV without touching the resident one.
    public abstract class SideConversation : IDisposable
    {
        public abstract IAsyncEnumerable<AgentDelta> StreamTurnAsync(string prompt, CancellationToken ct = default);
        public abstract void Dispose();
    }

    // Snapshot of the last turn's native benchmark counters (drives tok/s in the UI). Lives on the runtime
    // contract — a backend-agnostic type (relocated here from the removed JNI client).
    public sealed record Benchmark(double InitSeconds, double TimeToFirstTokenSeconds,
        int PrefillTokens, double PrefillTokensPerSecond, int DecodeTokens, double DecodeTokensPerSecond);
}
