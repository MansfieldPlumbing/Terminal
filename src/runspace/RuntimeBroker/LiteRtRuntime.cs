using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace Subsystem.RuntimeBroker
{
    // In-process LiteRT-LM Runtime for the Android head over the C API (P/Invoke against LiteRtNative),
    // additive beside the JNI LiteRtChatClient — the broker routes by the Runtime contract. Tokens cross
    // C++ -> CoreCLR directly through an [UnmanagedCallersOnly] function pointer: no JNI double-hop, no
    // GREF per token, and the native weights are reclaimed through SafeHandle on the Terminate/DropPrefix
    // cascade before the GC ever sees the wrapper. The model + system prompt are the CONTRACT handed in
    // by Rb (resolved from Cm), never held here; the runtime self-governs its placement (admission / OOM
    // budget) in BringUp.
    public sealed class LiteRtRuntime : Runtime
    {
        private readonly string _modelPath;
        private readonly string? _cacheDir;
        private readonly string? _systemInstruction;
        private readonly string _unitId;            // the \Capability\Model leaf this runtime serves
        private readonly int _maxTokens;            // KV window (set_max_num_tokens) — token budget before the context wall
        private readonly SamplerSpec? _sampler;     // the model's sampling contract (\Capability\Model\<id>.sampler); null => engine default

        private LiteRtLmEngineHandle? _engineHandle;
        private LiteRtLmConversationHandle? _conversationHandle;

        private readonly object _gate = new();
        private readonly SemaphoreSlim _turnGate = new(1, 1);
        private volatile bool _ready;
        private RbFault? _initFault;                // §3.1: typed bring-up fault; null = serviceable
        private string _backendName = "loading…";  // honest until the engine inits (then the real rung)
        private volatile bool _multimodal;          // true => engine brought up with vision/audio backends

        // The active turn's channel + splitter — the native callback forwards into these under _turnGate.
        private ChannelWriter<AgentDelta>? _activeChannel;
        private ThinkingSplitter? _activeSplitter;

        // The CONTRACT (model + system prompt) is resolved from the registry by Rb and handed in; the
        // runtime holds no truth of its own. cacheDir is the engine's weight/KV cache directory.
        public LiteRtRuntime(string modelPath, string unitId, string? systemInstruction = null, string? cacheDir = null, int maxTokens = 4096, SamplerSpec? sampler = null)
        {
            _modelPath = modelPath;
            _unitId = unitId;
            _systemInstruction = systemInstruction;
            _cacheDir = cacheDir;
            _maxTokens = maxTokens > 0 ? maxTokens : 4096;
            _sampler = sampler;
        }

        public bool IsAlive => _ready && _initFault == null && _conversationHandle != null && !_conversationHandle.IsInvalid && !_conversationHandle.IsClosed;
        public string BackendName => _backendName;

        // §4/§6: self-governed bring-up. Placement is planned HERE, before any engine is allocated —
        // accelerator OOM is a native fault undeliverable to managed code. CPU rung for now; structured
        // to admit gpu/npu once the SoC-matched accelerator .so's are resolvable. Returns the typed
        // fault, or null when the conversation is serviceable. Idempotent.
        public RbFault? BringUp()
        {
            if (_ready) return null;
            if (_initFault != null) return _initFault;

            lock (_gate)
            {
                if (_ready) return null;
                if (_initFault != null) return _initFault;

                // Accelerator ladder. GPU first (Adreno; relieves the CPU pass that was seizing the host
                // HTTP server under load), CPU as the guaranteed fallback. NPU/QNN is admitted only for a
                // QNN-compiled model (the path tags qualcomm/qcs/qnn) — a non-QNN .litertlm on the QNN
                // backend just fails and falls back, and QNN needs the on-device v73 .so stack + a v73 model.
                bool qnnModel = _modelPath.IndexOf("qualcomm", StringComparison.OrdinalIgnoreCase) >= 0
                             || _modelPath.IndexOf("qcs", StringComparison.OrdinalIgnoreCase) >= 0
                             || _modelPath.IndexOf("qnn", StringComparison.OrdinalIgnoreCase) >= 0;
                var admitted = qnnModel ? new[] { "npu", "gpu", "cpu" } : new[] { "gpu", "cpu" };
                string? lastDetail = null;
                foreach (var name in admitted)
                {
                    string targetBackend = name.ToLowerInvariant();
                    if (targetBackend != "cpu" && targetBackend != "gpu" && targetBackend != "npu")
                    {
                        targetBackend = "cpu";
                    }

                    try
                    {
                        // 1. Engine settings (model_path, backend_str, vision_backend_str, audio_backend_str).
                        // Gemma 4 is natively multimodal: bring the engine up with vision (on the compute
                        // backend) + audio (CPU) FIRST. If the loaded .litertlm carries no vision/audio
                        // encoder the create fails, so fall back to a text-only engine on the SAME backend —
                        // multimodal is best-effort and never regresses the proven text path. _multimodal
                        // records which path won (also surfaced to diagnostics).
                        LiteRtLmEngineHandle? CreateEngine(string? visionBackend, string? audioBackend)
                        {
                            var settings = LiteRtNative.litert_lm_engine_settings_create(
                                Utf8(_modelPath), Utf8(targetBackend),
                                visionBackend != null ? Utf8(visionBackend) : null,
                                audioBackend != null ? Utf8(audioBackend) : null);
                            if (settings.IsInvalid) { lastDetail = "engine settings create returned an invalid handle"; return null; }
                            using (settings)
                            {
                                if (!string.IsNullOrEmpty(_cacheDir))
                                    LiteRtNative.litert_lm_engine_settings_set_cache_dir(settings, Utf8(_cacheDir));

                                // QNN/NPU: point LiteRT's dispatch loader at the on-device QNN v73 libs
                                // (libQnnHtp.so + libQnnHtpV73Skel.so). Requires those .so's bundled in the APK
                                // AND a v73-compiled model (e.g. qcs8275); absent them, NPU bring-up fails and the
                                // ladder falls to GPU/CPU. Lib dir = the model's own directory (co-locate the .so's).
                                if (targetBackend == "npu")
                                {
                                    var qnnLibDir = System.IO.Path.GetDirectoryName(_modelPath);
                                    if (!string.IsNullOrEmpty(qnnLibDir))
                                        LiteRtNative.litert_lm_engine_settings_set_litert_dispatch_lib_dir(settings, Utf8(qnnLibDir));
                                }

                                // KV window: the token budget before LiteRT hits the context wall and output
                                // degrades sharply (no library-level context manager — LiteRT-LM issue #1878). Set
                                // it explicitly instead of riding the small default; the FIFO evictor
                                // (DeleteTokensFromKvCache) is the durable fix layered on top of this.
                                LiteRtNative.litert_lm_engine_settings_set_max_num_tokens(settings, _maxTokens);

                                // Collect TTFT + per-turn decode tok/s; read back after a turn (the BENCH log).
                                LiteRtNative.litert_lm_engine_settings_enable_benchmark(settings);

                                // 2. Engine.
                                var eng = LiteRtNative.litert_lm_engine_create(settings);
                                if (eng.IsInvalid) { eng.Dispose(); lastDetail = "engine create returned an invalid handle"; return null; }
                                return eng;
                            }
                        }

                        _engineHandle = CreateEngine(targetBackend, "cpu");
                        _multimodal = _engineHandle != null;
                        if (_engineHandle == null) _engineHandle = CreateEngine(null, null);
                        if (_engineHandle == null) continue;

                        // 3. Session config (sampling / output knobs).
                        var sessionConfig = LiteRtNative.litert_lm_session_config_create();
                        if (sessionConfig.IsInvalid)
                        {
                            lastDetail = "session config create returned an invalid handle";
                            _engineHandle.Dispose();
                            _engineHandle = null;
                            continue;
                        }

                        using (sessionConfig)
                        {
                            // Sampling is the model's generation CONTRACT (\Capability\Model\<id>.sampler),
                            // resolved by Rb and handed in — never a C# literal (SS020). Absent => the
                            // engine's own default. Type maps to LiteRtLmSamplerType (topP = top-k then top-p).
                            if (_sampler != null)
                            {
                                var sp = new LiteRtLmSamplerParams
                                {
                                    Type = _sampler.Type.ToLowerInvariant() switch { "topk" => 1, "topp" => 2, "greedy" => 3, _ => 0 },
                                    TopK = _sampler.TopK,
                                    TopP = _sampler.TopP,
                                    Temperature = _sampler.Temperature,
                                    Seed = _sampler.Seed,
                                };
                                LiteRtNative.litert_lm_session_config_set_sampler_params(sessionConfig, in sp);
                                Subsystem.Dg.Log("engine", $"SAMPLER {_unitId} type={_sampler.Type} topK={_sampler.TopK} topP={_sampler.TopP} temp={_sampler.Temperature} seed={_sampler.Seed}");
                            }

                            // System prompt + the registry's agent tools, folded into the monolithic
                            // conversation_config_create (the shipped .so's working path — patch_c_api.sh §5).
                            // The system message is the Cm-resolved CONTRACT; tools are projected to the
                            // OpenAI/LiteRT `tools` array, and the engine does the Gemma 4 template formatting
                            // and returns a structured `tool_calls` response (Conversation.kt) that the
                            // C#-driven loop services. No tools / no system prompt -> null (a NULL char* the
                            // .so skips; an empty tools array only adds template overhead). No seed messages.
                            byte[]? systemMsgJson = string.IsNullOrEmpty(_systemInstruction) ? null : Utf8(_systemInstruction);
                            var tools = ToolCatalog.Project();
                            byte[]? toolsJson = tools.Length > 0 ? Utf8(ToolCatalog.ProjectEngineJson(tools)) : null;

                            // Constrained decoding: when tools are projected, the bundled
                            // libGemmaModelConstraintProvider.so masks the vocabulary to the tool-call grammar
                            // during sampling, so a tool call parses on the first pass (no syntax-hallucination
                            // retry hops). Free prose is still permitted; the constraint only forbids malformed
                            // tool-call syntax. Off when there are no tools (nothing to constrain to).
                            byte constrain = (byte)(toolsJson != null ? 1 : 0);

                            // Build the Conversation, with an unconstrained FALLBACK. Constrained decoding
                            // drives the bundled libGemmaModelConstraintProvider, which is vocab/arch-specific
                            // (built for the E-class Gemmas); a model it cannot mask (e.g. the 12B) fails
                            // conversation_create with constrain=1. Rather than fail the whole bring-up, retry
                            // ONCE unconstrained so the unit stays serviceable — it can still emit tool calls,
                            // just without forced grammar. Degrade, never vanish.
                            LiteRtLmConversationHandle? TryCreateConversation(byte constrainByte)
                            {
                                var cc = LiteRtNative.litert_lm_conversation_config_create(
                                    _engineHandle, sessionConfig, systemMsgJson, toolsJson, null, constrainByte);
                                if (cc.IsInvalid) return null;
                                using (cc)
                                {
                                    // Keep the thinking channel out of persistent KV (Gemma 4 reasons verbosely).
                                    LiteRtNative.litert_lm_conversation_config_set_filter_channel_content_from_kv_cache(cc, 1);
                                    var conv = LiteRtNative.litert_lm_conversation_create(_engineHandle, cc);
                                    return conv.IsInvalid ? null : conv;
                                }
                            }

                            _conversationHandle = TryCreateConversation(constrain);
                            if (_conversationHandle == null && constrain == 1)
                            {
                                Subsystem.Dg.Log("engine", $"CONSTRAINT-FALLBACK {_unitId}: constrained conversation_create failed, retrying unconstrained");
                                _conversationHandle = TryCreateConversation(0);
                            }
                        }

                        // §6(d): liveness verification — the conversation object must exist before the
                        // unit is published as serviceable. The structural check is the zero-cost
                        // verification this layer can honestly make (a generation probe costs a prefill).
                        if (_conversationHandle == null || _conversationHandle.IsInvalid)
                        {
                            lastDetail = "conversation create returned an invalid handle";
                            _engineHandle.Dispose();
                            _engineHandle = null;
                            continue;
                        }

                        _backendName = name.ToUpperInvariant();
                        _ready = true;

                        // Ground-truth probe: render a sample user turn through the model's own Jinja template
                        // and log it ONCE, so the actual Gemma 4 control tokens (turn / thinking / tool-call
                        // delimiters) are recorded from the binary, not trusted from a doc.
                        try
                        {
                            var rendered = LiteRtNative.litert_lm_conversation_render_message_to_string(
                                _conversationHandle!, Utf8("{\"role\":\"user\",\"content\":\"hello\"}"));
                            if (rendered != IntPtr.Zero)
                                Subsystem.Dg.Log("engine", "TEMPLATE " + (Marshal.PtrToStringUTF8(rendered) ?? ""));
                        }
                        catch (Exception ex) { Subsystem.Dg.Warn("engine", ex); }

                        Subsystem.Dg.Log("engine", $"BRINGUP {_unitId} verified on {_backendName} (C API, mm={_multimodal})");
                        return null;
                    }
                    catch (Exception ex)
                    {
                        // The single point (§3.1) where bring-up exception text is read: degraded to the
                        // one diagnostic surface and retained only as opaque NativeDetail.
                        lastDetail = ex.Message;
                        Subsystem.Dg.Warn("engine", ex);
                    }
                }

                _initFault = new RbFault(RbFaultClass.BringUpFailed, _unitId,
                    string.Join("/", admitted), lastDetail ?? "no admitted backend initialized");
                return _initFault;
            }
        }

        // Stream one turn as structured events. Visible text and the thinking channel are split out of
        // the model's token stream by the splitter; the native callback drives both.
        public IAsyncEnumerable<AgentDelta> StreamTurnAsync(string prompt, byte[]? audioBytes, CancellationToken ct = default)
            => StreamTurnAsync(prompt, audioBytes, null, ct);

        // The multimodal turn. Image/audio bytes (when present) become content PARTS in the message JSON,
        // which the engine's Gemma3-class ModelDataProcessor preprocesses inline; text-only stays a bare
        // string. This is the same proven Conversation streaming path — tools and the system prompt are
        // untouched.
        public async IAsyncEnumerable<AgentDelta> StreamTurnAsync(string prompt, byte[]? audioBytes, byte[]? imageBytes, [EnumeratorCancellation] CancellationToken ct = default)
        {
            var fault = BringUp();
            if (fault != null)
            {
                yield return new AgentDelta(AgentDeltaKind.Error, fault.NativeDetail, Fault: fault);
                yield break;
            }
            await foreach (var delta in StreamOnAsync(_conversationHandle!, prompt, audioBytes, imageBytes, ct))
                yield return delta;
        }

        // The streaming core, parameterized by the conversation handle so the resident conversation AND an
        // ephemeral side-conversation (the web-agent fork) drive ONE proven turn path. The caller ensures
        // the engine is up; _turnGate serializes every turn on this runtime, so the per-turn channel /
        // splitter / callback fields never overlap regardless of which conversation is driven.
        internal async IAsyncEnumerable<AgentDelta> StreamOnAsync(LiteRtLmConversationHandle conv, string prompt, byte[]? audioBytes, byte[]? imageBytes, [EnumeratorCancellation] CancellationToken ct = default)
        {
            var channel = Channel.CreateUnbounded<AgentDelta>(new UnboundedChannelOptions { SingleReader = true, SingleWriter = false });
            var splitter = new ThinkingSplitter(channel.Writer);

            await _turnGate.WaitAsync(ct);

            // Pin THIS runtime so the native callback can resolve it from callback_data without a delegate
            // allocation. Freed in the finally, after the synchronous send returns and the channel drains.
            GCHandle gcHandle = GCHandle.Alloc(this, GCHandleType.Normal);
            IntPtr callbackData = GCHandle.ToIntPtr(gcHandle);

            using var ctReg = ct.Register(() =>
            {
                try
                {
                    if (!conv.IsInvalid)
                    {
                        LiteRtNative.litert_lm_conversation_cancel_process(conv);
                    }
                }
                catch (Exception ex) { Subsystem.Dg.Warn("engine", ex); }
            });

            _activeChannel = channel.Writer;
            _activeSplitter = splitter;

            try
            {
                // Text-only stays a bare string; with image/audio the content becomes a parts array (the
                // LiteRT-LM multimodal Message shape). Bytes cross as a base64 `blob` so no on-device file
                // path or storage permission is in play.
                string msgJson;
                if (imageBytes is { Length: > 0 } || audioBytes is { Length: > 0 })
                {
                    var parts = new List<object> { new { type = "text", text = prompt } };
                    if (imageBytes is { Length: > 0 }) parts.Add(new { type = "image", blob = Convert.ToBase64String(imageBytes) });
                    if (audioBytes is { Length: > 0 }) parts.Add(new { type = "audio", blob = Convert.ToBase64String(audioBytes) });
                    msgJson = JsonSerializer.Serialize(new { role = "user", content = parts });
                }
                else
                {
                    msgJson = JsonSerializer.Serialize(new { role = "user", content = prompt });
                }

                int res;
                unsafe
                {
                    res = LiteRtNative.litert_lm_conversation_send_message_stream(
                        conv,
                        Utf8(msgJson),
                        Utf8("{}"),
                        IntPtr.Zero,
                        &OnTokenCallback,
                        callbackData);
                }

                if (res != 0)
                {
                    channel.Writer.TryComplete(new RbFaultException(new RbFault(RbFaultClass.DecodeFaulted, _unitId, _backendName, $"send_message_stream returned {res}")));
                }

                await foreach (var delta in channel.Reader.ReadAllAsync(ct))
                {
                    yield return delta;
                }

                if (conv == _conversationHandle) LogBenchmark();
            }
            finally
            {
                _activeChannel = null;
                _activeSplitter = null;
                if (gcHandle.IsAllocated)
                {
                    gcHandle.Free();
                }
                _turnGate.Release();
            }
        }

        // Fork an ephemeral conversation on the SHARED engine with its own system prompt + tools + KV. The
        // weights are reused (no second model load); the KV is independent and freed on Dispose, so a sub-
        // agent's turns never enter the resident conversation — the "Conversation = per-agent unit" rule.
        // Constrained decoding is on only when tools are projected. Returns null if the engine is unserviceable.
        public SideConversation? OpenSideConversation(string? systemPrompt, ToolDescriptor[]? tools)
        {
            if (BringUp() != null) return null;
            lock (_gate)
            {
                var engine = _engineHandle;
                if (engine == null || engine.IsInvalid) { Subsystem.Dg.Warn("engine", "SIDE-CONV engine invalid/null"); return null; }

                var sessionConfig = LiteRtNative.litert_lm_session_config_create();
                if (sessionConfig.IsInvalid) { Subsystem.Dg.Warn("engine", "SIDE-CONV session_config invalid"); return null; }
                using (sessionConfig)
                {
                    if (_sampler != null)
                    {
                        var sp = new LiteRtLmSamplerParams
                        {
                            Type = _sampler.Type.ToLowerInvariant() switch { "topk" => 1, "topp" => 2, "greedy" => 3, _ => 0 },
                            TopK = _sampler.TopK,
                            TopP = _sampler.TopP,
                            Temperature = _sampler.Temperature,
                            Seed = _sampler.Seed,
                        };
                        LiteRtNative.litert_lm_session_config_set_sampler_params(sessionConfig, in sp);
                    }

                    byte[]? sysJson = string.IsNullOrEmpty(systemPrompt) ? null : Utf8(systemPrompt!);
                    byte[]? toolsJson = (tools != null && tools.Length > 0) ? Utf8(ToolCatalog.ProjectEngineJson(tools)) : null;
                    byte constrain = (byte)(toolsJson != null ? 1 : 0);

                    var convConfig = LiteRtNative.litert_lm_conversation_config_create(engine, sessionConfig, sysJson, toolsJson, null, constrain);
                    if (convConfig.IsInvalid) { Subsystem.Dg.Warn("engine", "SIDE-CONV conv_config invalid"); return null; }
                    using (convConfig)
                    {
                        LiteRtNative.litert_lm_conversation_config_set_filter_channel_content_from_kv_cache(convConfig, 1);
                        var conv = LiteRtNative.litert_lm_conversation_create(engine, convConfig);
                        if (conv.IsInvalid) { conv.Dispose(); Subsystem.Dg.Warn("engine", "SIDE-CONV conversation_create invalid"); return null; }
                        Subsystem.Dg.Log("engine", $"SIDE-CONV {_unitId} forked on {_backendName} (tools={(toolsJson != null ? 1 : 0)})");
                        return new LiteRtSideConversation(this, conv);
                    }
                }
            }
        }

        // The native callback's managed body. Error text is the §3.1 classification point: mapped into
        // the fault taxonomy, carried onward only as opaque NativeDetail.
        internal void OnChunk(string chunk, bool isFinal, string errorMsg)
        {
            try
            {
                if (!string.IsNullOrEmpty(errorMsg))
                {
                    var detail = errorMsg;
                    var cls = detail.Contains("not alive", StringComparison.OrdinalIgnoreCase) ? RbFaultClass.ConversationDefunct
                            : detail.Contains("cancel", StringComparison.OrdinalIgnoreCase)    ? RbFaultClass.DecodeCancelled
                            : RbFaultClass.DecodeFaulted;

                    _activeChannel?.TryComplete(new RbFaultException(new RbFault(cls, _unitId, _backendName, detail)));
                    return;
                }

                if (!string.IsNullOrEmpty(chunk))
                {
                    _activeSplitter?.Push(chunk);
                }

                if (isFinal)
                {
                    _activeSplitter?.Flush();
                    _activeChannel?.TryComplete();
                }
            }
            catch (Exception ex)
            {
                _activeChannel?.TryComplete(ex);
            }
        }

        // void(void* callback_data, const char* chunk, bool is_final, const char* error_msg). The C ABI
        // bool is one byte (marshalled as byte). Resolves THIS runtime from the pinned handle. A managed
        // exception must never cross back into C++, so the boundary degrades to Dg and returns.
        [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
        public static unsafe void OnTokenCallback(IntPtr callbackData, byte* chunkPtr, byte isFinalByte, byte* errorMsgPtr)
        {
            try
            {
                if (callbackData == IntPtr.Zero) return;

                GCHandle gcHandle = GCHandle.FromIntPtr(callbackData);
                if (gcHandle.Target is LiteRtRuntime runtime)
                {
                    string chunk = chunkPtr != null ? Marshal.PtrToStringUTF8((IntPtr)chunkPtr) ?? "" : "";
                    bool isFinal = isFinalByte != 0;
                    string errorMsg = errorMsgPtr != null ? Marshal.PtrToStringUTF8((IntPtr)errorMsgPtr) ?? "" : "";

                    runtime.OnChunk(chunk, isFinal, errorMsg);
                }
            }
            catch (Exception ex)
            {
                Subsystem.Dg.Warn("engine", ex);
            }
        }

        public void Dispose()
        {
            lock (_gate)
            {
                _conversationHandle?.Dispose();
                _conversationHandle = null;
                _engineHandle?.Dispose();
                _engineHandle = null;
            }
        }

        // Reads the native benchmark counters after a turn and logs the last decode rate + TTFT. This is
        // the honest GPU-vs-CPU measurement (the model is a deterministic computation; tok/s is the number
        // that moved when E2B went from CPU to the Adreno). Read-only and best-effort — never throws past
        // the diagnostic surface.
        // The C-API benchmark counters surfaced to the UI (the Runtime contract's Benchmark). Best-effort,
        // read-only; null until a decode turn has run. The C API exposes TTFT + per-turn decode tok/s, so
        // prefill/init counters stay 0 (libLiteRtLm doesn't surface them).
        public Benchmark? GetBenchmark()
        {
            try
            {
                if (_conversationHandle == null || _conversationHandle.IsInvalid) return null;
                using var bench = LiteRtNative.litert_lm_conversation_get_benchmark_info(_conversationHandle);
                if (bench == null || bench.IsInvalid) return null;
                int turns = LiteRtNative.litert_lm_benchmark_info_get_num_decode_turns(bench);
                if (turns <= 0) return null;
                double tps = LiteRtNative.litert_lm_benchmark_info_get_decode_tokens_per_sec_at(bench, turns - 1);
                double ttft = LiteRtNative.litert_lm_benchmark_info_get_time_to_first_token(bench);
                return new Benchmark(0, ttft, 0, 0, 0, tps);
            }
            catch (Exception ex) { Subsystem.Dg.Warn("engine", ex); return null; }
        }

        private void LogBenchmark()
        {
            var b = GetBenchmark();
            if (b != null) Subsystem.Dg.Log("engine", $"BENCH {_unitId} {_backendName} decode={b.DecodeTokensPerSecond:0.0} tok/s ttft={b.TimeToFirstTokenSeconds:0.000}s");
        }

        // UTF-8, null-terminated — how the LiteRT-LM C API expects its char* arguments. DllImport has no
        // UTF-8 string marshalling, so the binding declares byte[] and the runtime marshals here.
        private static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s + "\0");

        // An ephemeral conversation forked onto this runtime's engine. It streams through the SAME proven
        // core (StreamOnAsync); Dispose frees only this conversation's KV — the resident one is untouched.
        private sealed class LiteRtSideConversation : SideConversation
        {
            private readonly LiteRtRuntime _runtime;
            private LiteRtLmConversationHandle? _conv;

            public LiteRtSideConversation(LiteRtRuntime runtime, LiteRtLmConversationHandle conv)
            {
                _runtime = runtime;
                _conv = conv;
            }

            public override IAsyncEnumerable<AgentDelta> StreamTurnAsync(string prompt, CancellationToken ct = default)
            {
                var c = _conv ?? throw new ObjectDisposedException(nameof(LiteRtSideConversation));
                return _runtime.StreamOnAsync(c, prompt, null, null, ct);
            }

            public override void Dispose()
            {
                try { _conv?.Dispose(); } catch (Exception ex) { Subsystem.Dg.Warn("engine", ex); }
                _conv = null;
            }
        }

        // Splits cumulative model text into a visible-answer stream and a thinking stream. Gemma 4 emits
        // its reasoning inside `<|channel>` … `<channel|>`. We track how much of each we've emitted and
        // push only new suffixes, hiding a half-arrived marker so partial tokens never flash in the UI.
        private sealed class ThinkingSplitter
        {
            private const string Open = "<|channel>";
            private const string Close = "<channel|>";
            private readonly ChannelWriter<AgentDelta> _w;
            private int _emittedThink, _emittedAnswer;
            private string _buf = "";

            public ThinkingSplitter(ChannelWriter<AgentDelta> w) { _w = w; }

            public void Push(string chunk)
            {
                if (string.IsNullOrEmpty(chunk)) return;
                chunk = CleanText(chunk);
                // The native callback may deliver cumulative OR incremental text — normalize to cumulative.
                _buf = chunk.StartsWith(_buf, StringComparison.Ordinal) ? chunk : _buf + chunk;
                string full = _buf;
                string answer, think;
                int o = full.IndexOf(Open, StringComparison.Ordinal);
                if (o < 0) { answer = full; think = ""; }
                else
                {
                    int ts = o + Open.Length;
                    int c = full.IndexOf(Close, ts, StringComparison.Ordinal);
                    if (c < 0) { think = full.Substring(ts); answer = full.Substring(0, o); }
                    else { think = full.Substring(ts, c - ts); answer = full.Substring(0, o) + full.Substring(c + Close.Length); }
                }
                answer = TrimTrailingPartialMarker(answer);

                if (think.Length > _emittedThink) { _w.TryWrite(new AgentDelta(AgentDeltaKind.Think, think.Substring(_emittedThink))); _emittedThink = think.Length; }
                if (answer.Length > _emittedAnswer) { _w.TryWrite(new AgentDelta(AgentDeltaKind.Token, answer.Substring(_emittedAnswer))); _emittedAnswer = answer.Length; }
            }

            public void Flush() { }

            // If the tail looks like the start of either marker, hold it back so it never flashes.
            private static string TrimTrailingPartialMarker(string s)
            {
                foreach (var mk in new[] { Open, Close })
                    for (int len = Math.Min(mk.Length - 1, s.Length); len > 0; len--)
                        if (s.EndsWith(mk.Substring(0, len), StringComparison.Ordinal)) return s.Substring(0, s.Length - len);
                return s;
            }

            // A token chunk may be a JsonMessage dump; pull the text out if so. MUST NOT trim — streaming
            // deltas carry significant leading spaces (the "▁am" token = " am").
            private static string CleanText(string raw)
            {
                var probe = raw.TrimStart();
                if (!probe.StartsWith("{") && !probe.StartsWith("[")) return raw;
                try
                {
                    using var doc = JsonDocument.Parse(raw);
                    var root = doc.RootElement;
                    if (root.TryGetProperty("content", out var c))
                    {
                        if (c.ValueKind == JsonValueKind.String) return c.GetString() ?? raw;
                        if (c.ValueKind == JsonValueKind.Array)
                        {
                            var sb = new StringBuilder();
                            foreach (var part in c.EnumerateArray())
                                if (part.TryGetProperty("text", out var t)) sb.Append(t.GetString());
                            if (sb.Length > 0) return sb.ToString();
                        }
                    }
                }
                catch (Exception ex) { Subsystem.Dg.Warn("engine", ex); }
                return raw;
            }
        }
    }
}
