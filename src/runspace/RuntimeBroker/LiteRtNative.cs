using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Subsystem.RuntimeBroker
{
    // LiteRtNative — the home-spun P/Invoke binding to the LiteRT-LM C API (c/engine.h), shared VERBATIM
    // by both heads: the Windows head loads litert-lm.dll, the Android head loads libLiteRtLm.so. ONE
    // binding, no JNI, no #if ANDROID — the JNI double-hop (C++ -> ART -> CoreCLR, a GREF per token) is
    // gone; tokens cross C++ -> CoreCLR directly through an [UnmanagedCallersOnly] function pointer.
    //
    // Ground truth is c/engine.h (NOT an SDK, NOT a generated stub) — we wrote the Windows binding the same
    // way in under an hour, so the Android binding is the SAME code pointed at the same symbols. Classic
    // [DllImport] (never source-generated [LibraryImport]): the in-proc Roslyn of `ss build self` runs no
    // source generators, so a generated binding would compile under dotnet but break the self-hosting build
    // (prime-directive rule 0). DllImport has no UTF-8 marshalling, so char* args cross as Utf8() byte[].
    //
    // Resource discipline (VOM): every opaque pointer is a SafeHandle, so litert_lm_*_delete runs
    // deterministically on the Terminate/DropPrefix cascade — the 2.6 GB of weights is reclaimed before the
    // GC ever sees the wrapper, keeping the native footprint opaque to ART's Java-heap OOM killer.

    // ---- opaque-pointer SafeHandles (free-at-zero, owns the native resource) ----

    public sealed class LiteRtLmEngineSettingsHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public LiteRtLmEngineSettingsHandle() : base(true) { }
        protected override bool ReleaseHandle() { LiteRtNative.litert_lm_engine_settings_delete(handle); return true; }
    }

    public sealed class LiteRtLmEngineHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public LiteRtLmEngineHandle() : base(true) { }
        protected override bool ReleaseHandle() { LiteRtNative.litert_lm_engine_delete(handle); return true; }
    }

    public sealed class LiteRtLmSessionConfigHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public LiteRtLmSessionConfigHandle() : base(true) { }
        protected override bool ReleaseHandle() { LiteRtNative.litert_lm_session_config_delete(handle); return true; }
    }

    public sealed class LiteRtLmConversationConfigHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public LiteRtLmConversationConfigHandle() : base(true) { }
        protected override bool ReleaseHandle() { LiteRtNative.litert_lm_conversation_config_delete(handle); return true; }
    }

    public sealed class LiteRtLmConversationOptionalArgsHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public LiteRtLmConversationOptionalArgsHandle() : base(true) { }
        protected override bool ReleaseHandle() { LiteRtNative.litert_lm_conversation_optional_args_delete(handle); return true; }
    }

    public sealed class LiteRtLmConversationHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public LiteRtLmConversationHandle() : base(true) { }
        protected override bool ReleaseHandle() { LiteRtNative.litert_lm_conversation_delete(handle); return true; }
    }

    public sealed class LiteRtLmBenchmarkInfoHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public LiteRtLmBenchmarkInfoHandle() : base(true) { }
        protected override bool ReleaseHandle() { LiteRtNative.litert_lm_benchmark_info_delete(handle); return true; }
    }

    // Sampler knobs (c/engine.h LiteRtLmSamplerParams). A per-runtime knob, set on the session config.
    [StructLayout(LayoutKind.Sequential)]
    public struct LiteRtLmSamplerParams
    {
        public int Type;          // LiteRtLmSamplerType: 0=unspecified 1=topK 2=topP 3=greedy
        public int TopK;
        public float TopP;
        public float Temperature;
        public int Seed;
    }

    // ---- the binding surface (c/engine.h) ----
    internal static unsafe class LiteRtNative
    {
        // On Android the loader resolves lib<name>.so -> libLiteRtLm.so, the monolithic flutter_gemma
        // prebuilt (LiteRt linked in, with the patched GPU sampler + QNN stack beside it). That .so
        // filename is a foreign native-asset name (locked by the prebuilt samplers' DT_NEEDED) — fenced
        // to this one interop file, never entering the object namespace. The Windows head's own binding
        // loads litert-lm.dll through its DllImportResolver.
        private const string Dll = "LiteRtLm";

        // char* args cross as null-terminated UTF-8 byte[] (DllImport marshals byte[] as a pointer to the
        // array); the caller marshals via a private Utf8 helper on the runtime — the binding declares only.

        // Streaming callback: void(void* callback_data, const char* chunk, bool is_final, const char* error_msg).
        // bool in the C ABI is 1 byte; we marshal it as `byte` to match the [UnmanagedCallersOnly] target.

        [DllImport(Dll)] public static extern void litert_lm_set_min_log_level(int level);

        // -- engine settings + its knobs (each runtime governs its OWN knob-bag) --
        [DllImport(Dll)] public static extern LiteRtLmEngineSettingsHandle litert_lm_engine_settings_create(
            byte[] modelPath, byte[] backendStr, byte[]? visionBackendStr, byte[]? audioBackendStr);
        [DllImport(Dll)] public static extern void litert_lm_engine_settings_delete(IntPtr settings);
        [DllImport(Dll)] public static extern void litert_lm_engine_settings_set_cache_dir(LiteRtLmEngineSettingsHandle s, byte[] cacheDir);
        [DllImport(Dll)] public static extern void litert_lm_engine_settings_set_max_num_tokens(LiteRtLmEngineSettingsHandle s, int maxNumTokens);
        [DllImport(Dll)] public static extern void litert_lm_engine_settings_set_max_num_images(LiteRtLmEngineSettingsHandle s, int maxNumImages);
        [DllImport(Dll)] public static extern void litert_lm_engine_settings_set_num_threads(LiteRtLmEngineSettingsHandle s, int numThreads);
        [DllImport(Dll)] public static extern void litert_lm_engine_settings_set_enable_speculative_decoding(LiteRtLmEngineSettingsHandle s, byte enable);
        [DllImport(Dll)] public static extern void litert_lm_engine_settings_set_litert_dispatch_lib_dir(LiteRtLmEngineSettingsHandle s, byte[] libDir);
        // Turns on the engine's benchmark counters (TTFT, per-turn decode tok/s) — read back through
        // litert_lm_conversation_get_benchmark_info after a turn. A counter-collection flag, not a
        // benchmark-only run mode; the streaming send is unchanged.
        [DllImport(Dll)] public static extern void litert_lm_engine_settings_enable_benchmark(LiteRtLmEngineSettingsHandle s);

        [DllImport(Dll)] public static extern LiteRtLmEngineHandle litert_lm_engine_create(LiteRtLmEngineSettingsHandle settings);
        [DllImport(Dll)] public static extern void litert_lm_engine_delete(IntPtr engine);

        // -- session config (sampling / output knobs) --
        [DllImport(Dll)] public static extern LiteRtLmSessionConfigHandle litert_lm_session_config_create();
        [DllImport(Dll)] public static extern void litert_lm_session_config_delete(IntPtr config);
        [DllImport(Dll)] public static extern void litert_lm_session_config_set_max_output_tokens(LiteRtLmSessionConfigHandle c, int maxOutputTokens);
        [DllImport(Dll)] public static extern void litert_lm_session_config_set_apply_prompt_template(LiteRtLmSessionConfigHandle c, byte applyPromptTemplate);
        [DllImport(Dll)] public static extern void litert_lm_session_config_set_sampler_params(LiteRtLmSessionConfigHandle c, in LiteRtLmSamplerParams samplerParams);

        // -- conversation config (system prompt + TOOLS — the granular tool surface) --
        // The shipped flutter_gemma native-v0.12.0 .so exports the MONOLITHIC 6-arg create: patch_c_api.sh
        // §5 rewrites upstream's no-arg create() to fold session_config + system/tools/messages JSON +
        // constrained-decoding into one call. Ground truth is flutter_gemma's own proven Dart FFI binding
        // (litert_lm_bindings.dart): (engine, session_config, system_message_json, tools_json,
        // messages_json, bool). A 0-arg declaration ABI-mismatches — ARM64 reads the 6 arg-registers as
        // garbage and the .so dereferences them (the SIGSEGV in BringUp). The optional char* args cross as
        // null-terminated byte[] (null => NULL ptr); enable_constrained_decoding is the 1-byte C ABI bool.
        // The separate set_* setters below remain as real exports (kept for the seed-message / KV-filter
        // paths the agentic loop will use), but the working BringUp path uses this monolithic create.
        [DllImport(Dll)] public static extern LiteRtLmConversationConfigHandle litert_lm_conversation_config_create(
            LiteRtLmEngineHandle engine, LiteRtLmSessionConfigHandle sessionConfig,
            byte[]? systemMessageJson, byte[]? toolsJson, byte[]? messagesJson, byte enableConstrainedDecoding);
        [DllImport(Dll)] public static extern void litert_lm_conversation_config_delete(IntPtr config);
        // Drops the model's thinking-channel tokens from the persistent KV cache (they fill the window
        // fastest). Real export in the shipped .so (litert_lm_bindings.dart); bool crosses as a 1-byte ABI flag.
        [DllImport(Dll)] public static extern void litert_lm_conversation_config_set_filter_channel_content_from_kv_cache(LiteRtLmConversationConfigHandle c, byte filter);
        [DllImport(Dll)] public static extern void litert_lm_conversation_config_set_session_config(LiteRtLmConversationConfigHandle c, LiteRtLmSessionConfigHandle sessionConfig);
        [DllImport(Dll)] public static extern void litert_lm_conversation_config_set_system_message(LiteRtLmConversationConfigHandle c, byte[] systemMessageJson);
        [DllImport(Dll)] public static extern void litert_lm_conversation_config_set_tools(LiteRtLmConversationConfigHandle c, byte[] toolsJson);
        [DllImport(Dll)] public static extern void litert_lm_conversation_config_set_messages(LiteRtLmConversationConfigHandle c, byte[] messagesJson);
        [DllImport(Dll)] public static extern void litert_lm_conversation_config_set_extra_context(LiteRtLmConversationConfigHandle c, byte[] extraContextJson);
        [DllImport(Dll)] public static extern void litert_lm_conversation_config_set_enable_constrained_decoding(LiteRtLmConversationConfigHandle c, byte enable);

        // -- per-turn optional args (visual budget, output cap) --
        [DllImport(Dll)] public static extern LiteRtLmConversationOptionalArgsHandle litert_lm_conversation_optional_args_create();
        [DllImport(Dll)] public static extern void litert_lm_conversation_optional_args_delete(IntPtr optionalArgs);
        [DllImport(Dll)] public static extern void litert_lm_conversation_optional_args_set_visual_token_budget(LiteRtLmConversationOptionalArgsHandle a, int visualTokenBudget);
        [DllImport(Dll)] public static extern void litert_lm_conversation_optional_args_set_max_output_tokens(LiteRtLmConversationOptionalArgsHandle a, int maxOutputTokens);

        // -- conversation lifecycle + the streaming turn --
        [DllImport(Dll)] public static extern LiteRtLmConversationHandle litert_lm_conversation_create(LiteRtLmEngineHandle engine, LiteRtLmConversationConfigHandle config);
        [DllImport(Dll)] public static extern void litert_lm_conversation_delete(IntPtr conversation);
        [DllImport(Dll)] public static extern LiteRtLmConversationHandle litert_lm_conversation_clone(LiteRtLmConversationHandle conversation);
        [DllImport(Dll)] public static extern void litert_lm_conversation_cancel_process(LiteRtLmConversationHandle conversation);
        [DllImport(Dll)] public static extern int litert_lm_conversation_get_token_count(LiteRtLmConversationHandle conversation);

        // Renders a message through the model's Jinja template WITHOUT sending it — the ground-truth probe
        // for Gemma 4's actual control tokens (the turn / thinking / tool-call delimiters). Returns a
        // const char* owned by the conversation (NULL on failure); copy it before the next call.
        [DllImport(Dll)] public static extern IntPtr litert_lm_conversation_render_message_to_string(LiteRtLmConversationHandle conversation, byte[] messageJson);

        // The high-frequency streaming send. `extra_context` + `optional_args` may be null (IntPtr.Zero for
        // optional_args). The callback is a C# 9 function pointer ([UnmanagedCallersOnly]) — zero delegate
        // alloc, no GC-relocation hazard across the native boundary.
        [DllImport(Dll)] public static extern int litert_lm_conversation_send_message_stream(
            LiteRtLmConversationHandle conversation,
            byte[] messageJson,
            byte[]? extraContextJson,
            IntPtr optionalArgs,
            delegate* unmanaged[Cdecl]<IntPtr, byte*, byte, byte*, void> callback,
            IntPtr callbackData);

        // -- benchmark counters (drive tok/s) --
        [DllImport(Dll)] public static extern LiteRtLmBenchmarkInfoHandle litert_lm_conversation_get_benchmark_info(LiteRtLmConversationHandle conversation);
        [DllImport(Dll)] public static extern void litert_lm_benchmark_info_delete(IntPtr benchmarkInfo);
        [DllImport(Dll)] public static extern double litert_lm_benchmark_info_get_time_to_first_token(LiteRtLmBenchmarkInfoHandle b);
        [DllImport(Dll)] public static extern double litert_lm_benchmark_info_get_total_init_time_in_second(LiteRtLmBenchmarkInfoHandle b);
        [DllImport(Dll)] public static extern int litert_lm_benchmark_info_get_num_prefill_turns(LiteRtLmBenchmarkInfoHandle b);
        [DllImport(Dll)] public static extern int litert_lm_benchmark_info_get_num_decode_turns(LiteRtLmBenchmarkInfoHandle b);
        [DllImport(Dll)] public static extern int litert_lm_benchmark_info_get_prefill_token_count_at(LiteRtLmBenchmarkInfoHandle b, int index);
        [DllImport(Dll)] public static extern int litert_lm_benchmark_info_get_decode_token_count_at(LiteRtLmBenchmarkInfoHandle b, int index);
        [DllImport(Dll)] public static extern double litert_lm_benchmark_info_get_prefill_tokens_per_sec_at(LiteRtLmBenchmarkInfoHandle b, int index);
        [DllImport(Dll)] public static extern double litert_lm_benchmark_info_get_decode_tokens_per_sec_at(LiteRtLmBenchmarkInfoHandle b, int index);
    }
}
