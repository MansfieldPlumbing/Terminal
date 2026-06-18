using System;

namespace Subsystem.RuntimeBroker
{
    // Hud — the pinned sitrep (AGENT-SPEC §2/§3): a deterministic projection of device vitals the
    // harness re-asserts at the front of EVERY turn. The model never tool-calls for vitals and never
    // trusts its own stale memory of them — drift is mitigated by relentless re-projection (axiom 3:
    // intelligence and correctness live in the deterministic harness, not the model).
    //
    // Fidelity note: §2 wants the HUD pinned at the head of the KV working set each tick. LiteRT-LM's
    // Conversation API owns the KV layout (append-only), so the available injection point is the head
    // of each USER turn — same invariant (fresh state every loop), engine-managed layout. Revisit when
    // Mm owns the working set (the HdLlama backend, spec §14).
    public static class Hud
    {
        // Compact + denotative (~30 tokens — E2B is small; the HUD must be cheap). Values come from the
        // \Device\Android\* drivers in-proc: deterministic reads, no runspace, no model in the loop.
        // Banding per §3: Vitals first (time, battery, net, memory), then identity (model/backend).
        public static string Assemble(string model, string backend)
        {
            var sb = new System.Text.StringBuilder("[HUD ");
            sb.Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm ddd"));
            try
            {
                var b = Subsystem.Device.Power.GetBatteryStatus();
                if (b.TryGetValue("Level", out var lvl))
                {
                    sb.Append(" | batt ").Append(lvl).Append('%');
                    if (b.TryGetValue("IsCharging", out var c) && c is bool cb && cb) sb.Append(" charging");
                }
            }
            catch { }
            try
            {
                var n = Subsystem.Device.Network.GetNetworkInfo();
                bool wifi = n.TryGetValue("HasWiFi", out var w) && w is bool wb && wb;
                bool cell = n.TryGetValue("HasCellular", out var ce) && ce is bool eb && eb;
                bool conn = n.TryGetValue("IsConnected", out var ic) && ic is bool icb && icb;
                sb.Append(" | net ").Append(wifi ? "wifi" : cell ? "cellular" : conn ? "connected" : "offline");
            }
            catch { }
            try
            {
                var m = Subsystem.Device.Memory.GetMemoryInfo();
                if (m.TryGetValue("AvailableBytes", out var av) && m.TryGetValue("TotalBytes", out var tt))
                    sb.Append(" | mem ")
                      .Append(Math.Round(Convert.ToInt64(av) / 1073741824.0, 1)).Append('/')
                      .Append(Math.Round(Convert.ToInt64(tt) / 1073741824.0, 1)).Append("GB free");
            }
            catch { }
            if (!string.IsNullOrEmpty(model)) sb.Append(" | model ").Append(model).Append('/').Append(backend);
            sb.Append(']');
            return sb.ToString();
        }

        // Pin the sitrep to the head of a user turn. The raw user text is what gets PERSISTED
        // (pure timeline fidelity, §1.5) — the HUD is projection, never transcript truth.
        public static string Wrap(string userText, string model, string backend)
            => Assemble(model, backend) + "\n" + userText;
    }
}
