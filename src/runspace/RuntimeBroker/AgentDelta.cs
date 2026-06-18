namespace Subsystem.RuntimeBroker
{
    // The agent turn's streamed event vocabulary — runtime-agnostic, shared by the C-API LiteRtRuntime,
    // the Broker, and the /agent surface. The tool surface is ToolCatalog (projected from the Cm registry,
    // never engine-typed).
    public enum AgentDeltaKind { Token, Think, ToolCall, ToolResult, Error }

    // One streamed event of an agent turn. Token/Think carry visible/thinking text; ToolCall/ToolResult
    // carry a tool name + a JSON payload so the UI can card the activity. An Error delta carries the
    // structured fault record; Text duplicates its NativeDetail for display-only consumers.
    public readonly record struct AgentDelta(AgentDeltaKind Kind, string Text, string? Name = null, RbFault? Fault = null);
}
