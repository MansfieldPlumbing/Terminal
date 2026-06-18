using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;

namespace Subsystem.RuntimeBroker
{
    // A runtime-agnostic tool descriptor projected from the Cm registry — MCP-shaped (name / description /
    // inputSchema), carrying NO engine types (no Java.Lang.Object, no LM.IOpenApiTool). The JNI runtime,
    // the C-API runtime, and the coming C#-driven tool loop consume the SAME descriptors, so the tool graph
    // is no longer trapped inside one engine's native loop. The execution `command` is OUR private detail
    // and must never reach the model — only Name/Description/InputSchema do.
    public sealed record ToolDescriptor(string Name, string Description, string InputSchemaJson, string Command, bool Sensitive);

    // Projects the registry's agentTool manifests into MCP descriptors. The tool DEFINITIONS still live in
    // the one namespace (\Capability\AgentTool\*, seeded from shell/agent-tools.json) — this projects them,
    // never hardcodes a tool. The complete runtime-agnostic tool surface: project the descriptors, serialize
    // them to either wire shape (MCP inputSchema / engine parameters), and Execute one by name — consent-gated,
    // in the runspace (the proven DeviceTool path). The C#-driven loop calls Execute on each model tool_call.
    public static class ToolCatalog
    {
        // Project every enabled capability whose manifest declares an `agentTool` block into a descriptor.
        public static ToolDescriptor[] Project()
        {
            var tools = new List<ToolDescriptor>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                foreach (var r in Subsystem.Cm.Cm.List())
                {
                    if (!r.Enabled || string.IsNullOrEmpty(r.ManifestJson)) continue;
                    var d = ParseDescriptor(r.ManifestJson!);
                    if (d != null && seen.Add(d.Name)) tools.Add(d);
                }
            }
            catch (Exception ex) { Subsystem.Dg.Warn("rb", ex); }
            return tools.ToArray();
        }

        // The MCP tools array ([{name, description, inputSchema}, ...]) a runtime injects into the model's
        // context (prompt or the C-API set_tools). The `command` is deliberately omitted — it is execution
        // detail, never tool schema the model should see.
        public static string ProjectJson(ToolDescriptor[] tools)
        {
            var sb = new StringBuilder();
            sb.Append('[');
            for (int i = 0; i < tools.Length; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append("{\"name\":").Append(JsonSerializer.Serialize(tools[i].Name))
                  .Append(",\"description\":").Append(JsonSerializer.Serialize(tools[i].Description))
                  .Append(",\"inputSchema\":").Append(tools[i].InputSchemaJson)
                  .Append('}');
            }
            sb.Append(']');
            return sb.ToString();
        }

        // The OpenAI / LiteRT-LM `tools` array the C-API set_tools expects (engine_test.cc):
        // [{"type":"function","function":{"name","description","parameters":<schema>}}]. `parameters` is the
        // SAME JSON Schema our descriptor holds as inputSchema — one truth, two wire shapes (MCP inputSchema
        // at the network seam, OpenAI parameters at the engine seam). Must be a JSON array or the engine
        // drops all tools.
        public static string ProjectEngineJson(ToolDescriptor[] tools)
        {
            var sb = new StringBuilder();
            sb.Append('[');
            for (int i = 0; i < tools.Length; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append("{\"type\":\"function\",\"function\":{\"name\":").Append(JsonSerializer.Serialize(tools[i].Name))
                  .Append(",\"description\":").Append(JsonSerializer.Serialize(tools[i].Description))
                  .Append(",\"parameters\":").Append(tools[i].InputSchemaJson)
                  .Append("}}");
            }
            sb.Append(']');
            return sb.ToString();
        }

        // MCP vocab is additive: the input schema reads from `inputSchema` (MCP) OR the legacy `parameters`
        // (Gemini function-declaration) — both are JSON Schema objects, so old manifests keep working while
        // new ones speak MCP. Absent both, the empty object schema is used.
        private static ToolDescriptor? ParseDescriptor(string manifestJson)
        {
            try
            {
                using var doc = JsonDocument.Parse(manifestJson);
                if (!doc.RootElement.TryGetProperty("agentTool", out var at) || at.ValueKind != JsonValueKind.Object) return null;
                string name = at.TryGetProperty("name", out var nv) ? (nv.GetString() ?? "") : "";
                string command = at.TryGetProperty("command", out var cv) ? (cv.GetString() ?? "") : "";
                if (name.Length == 0 || command.Length == 0) return null;
                string description = at.TryGetProperty("description", out var dv) ? (dv.GetString() ?? "") : "";
                string inputSchema =
                      at.TryGetProperty("inputSchema", out var iv) && iv.ValueKind == JsonValueKind.Object ? iv.GetRawText()
                    : at.TryGetProperty("parameters", out var pv) && pv.ValueKind == JsonValueKind.Object ? pv.GetRawText()
                    : "{\"type\":\"object\",\"properties\":{}}";
                bool sensitive = (at.TryGetProperty("sensitive", out var sv) && sv.ValueKind == JsonValueKind.True)
                                 || IsHardwareName(name);
                return new ToolDescriptor(name, description, inputSchema, command, sensitive);
            }
            catch (Exception ex) { Subsystem.Dg.Warn("rb", ex); return null; }
        }

        // Dispatch a tool by name with the model's args JSON, consent-gated: a sensitive (hardware) tool
        // fires only with possession of \Capability\Consent\Hardware — absent = denied, recorded, NOT run.
        // Args are exposed to the declared command as $ToolArgs in the runspace (the proven DeviceTool path).
        // Returns the tool's JSON result; a failure degrades to a typed JSON error, never a thrown exception.
        public static string Execute(string toolName, string argsJson)
        {
            var tool = Array.Find(Project(), t => string.Equals(t.Name, toolName, StringComparison.OrdinalIgnoreCase));
            if (tool == null) return "{\"error\":\"unknown tool\"}";
            if (tool.Sensitive && !(Subsystem.Cm.Cm.Get(HardwareConsentPath) is { Enabled: true }))
            {
                Subsystem.Dg.Warn("rb", $"tool '{toolName}' DENIED — hardware consent not granted");
                return "{\"error\":\"hardware tool not consented\"}";
            }
            try
            {
                // Args cross as DATA, never script text. The model's argsJson is base64-encoded here; the
                // base64 alphabet ([A-Za-z0-9+/=]) has no quote, newline, or '@, so it cannot break out of the
                // single-quoted literal — a hostile or hallucinated arg can't inject PowerShell. The declared
                // command is registry-trusted; only the args are untrusted, and stay inert until ConvertFrom-Json
                // parses them on-device. The injection class dies at this boundary (the Rs.cs discipline).
                var argsB64 = System.Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(argsJson ?? "{}"));
                var script = "$ToolArgs = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + argsB64 + "')) | ConvertFrom-Json; " + tool.Command;
                return Subsystem.SubsystemApi.ExecuteCommandAsJson(script).GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                Subsystem.Dg.Warn("rb", ex);
                return "{\"error\":\"" + (ex.Message ?? "tool failed").Replace("\"", "'") + "\"}";
            }
        }

        private const string HardwareConsentPath = "\\Capability\\Consent\\Hardware";

        // Hardware tools sensitive by name even when a manifest omits `sensitive:true` — they fire only with
        // possession of \Capability\Consent\Hardware (the gate the loop's dispatch enforces).
        private static bool IsHardwareName(string name)
            => string.Equals(name, "set_flashlight", StringComparison.OrdinalIgnoreCase)
            || string.Equals(name, "vibrate", StringComparison.OrdinalIgnoreCase);
    }
}
