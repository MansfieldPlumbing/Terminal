using System;
using System.Collections.Generic;
using System.Threading;

namespace Subsystem.Vom;

// The doorbell (VOM-SPEC Mailbox/Doorbell). A monotonic u64 timeline barrier — named for the
// D3D12/Vulkan fence it mirrors, NOT a counting Semaphore (resource counter) and NOT an Event
// (binary flip). Abstract base (no `I` prefix, per the Cutler naming law): CpuFence is the Tier-1
// backend today; VulkanFence (timeline semaphore) slots in at the GPU/NPU tier with the SAME surface
// and zero driver changes.
public abstract class Fence
{
    public abstract ulong CompletedValue { get; }
    public abstract void  Signal(ulong value);   // producer doorbell: advance the timeline
    public abstract void  Wait(ulong value);      // park until CompletedValue >= value (GPU queue-wait tier later)
    public abstract void  CpuWait(ulong value);   // OS-scheduler wait; final readback only

    // --- Phase-lock primitives: the multiplexer is a PHASE LOCK, not a switchboard ---
    // The monotonic fence value IS the phase/clock; waiters recheck the value, so no wake is ever lost.
    // Both park at the OS level (futex-backed Monitor): zero CPU while waiting, no GC, no async — which is
    // why phase survives where async/await would shatter it on the ThreadPool's work-stealing queue.
    //
    //   WaitAll — the BARRIER (DATA): park until EVERY fence has reached its target phase. This is how
    //     tensors lock — the LLM consumer does WaitAll(visionFence@N, audioFence@N) and evaluates only
    //     once both embeddings are at phase N, so the context never tears.
    //   WaitAny — the SWITCHBOARD (CONTROL): park until ANY fence reaches its target; returns its index
    //     (which worker needs attention).
    //
    // Tier-1 requires CpuFence; a GPU/NPU fence overrides these with vkWaitSemaphores(WAIT_ALL/ANY).
    public static void WaitAll(Fence[] fences, ulong[] targets) => WaitGroup(fences, targets, all: true);
    public static int  WaitAny(Fence[] fences, ulong[] targets) => WaitGroup(fences, targets, all: false);

    private static int WaitGroup(Fence[] fences, ulong[] targets, bool all)
    {
        if (fences is null || targets is null || fences.Length != targets.Length || fences.Length == 0)
            throw new ArgumentException("WaitGroup needs matching, non-empty fence + target arrays.");

        int hit = Ready(fences, targets, all);
        if (hit >= 0) return hit;                       // already phased — never park needlessly

        var gate = new object();                        // one shared notify channel for this wait
        var registered = new List<CpuFence>(fences.Length);
        foreach (var f in fences)
        {
            if (f is not CpuFence c)
                throw new NotSupportedException("Tier-1 WaitAll/WaitAny requires CpuFence; mixed-tier groups are a later tier.");
            c.Register(gate);
            registered.Add(c);
        }
        try
        {
            lock (gate)
            {
                while ((hit = Ready(fences, targets, all)) < 0)
                    Monitor.Wait(gate);                 // futex park; any registered Signal re-checks us
                return hit;
            }
        }
        finally { foreach (var c in registered) c.Unregister(gate); }
    }

    // WaitAny: index of the first fence at/over its target, else -1. WaitAll: 0 once all are, else -1.
    private static int Ready(Fence[] fences, ulong[] targets, bool all)
    {
        bool allMet = true;
        for (int i = 0; i < fences.Length; i++)
        {
            bool met = fences[i].CompletedValue >= targets[i];
            if (!all && met) return i;
            if (!met) allMet = false;
        }
        return all && allMet ? 0 : -1;
    }
}

// Tier-1 CPU fence: an Interlocked u64 timeline + a futex-backed park. Monitor on Linux/Android is
// futex-backed, so Wait() parks the thread in the kernel (effectively zero-CPU) until Signal()
// advances the value. This is the correct primitive for CPU->CPU handoffs (e.g. \Capture\Mic -> Hb);
// reach for VulkanFence only when data crosses to the GPU/NPU.
public sealed class CpuFence : Fence
{
    private long _value;
    private readonly object _gate = new();
    private readonly HashSet<object> _groups = new();   // shared group gates pulsed on Signal (WaitAll/Any)

    public override ulong CompletedValue => (ulong)Interlocked.Read(ref _value);

    public override void Signal(ulong value)
    {
        object[]? groups = null;
        lock (_gate)
        {
            if ((long)value > _value) _value = (long)value;
            Monitor.PulseAll(_gate);
            if (_groups.Count > 0) { groups = new object[_groups.Count]; _groups.CopyTo(groups); }
        }
        // Wake group waiters OUTSIDE _gate — lock order is always _gate-then-group, never the reverse,
        // so WaitGroup (which holds only the group gate) can never deadlock against Signal.
        if (groups != null)
            foreach (var g in groups) lock (g) Monitor.PulseAll(g);
    }

    public override void Wait(ulong value)
    {
        lock (_gate)
        {
            while ((ulong)_value < value) Monitor.Wait(_gate);
        }
    }

    public override void CpuWait(ulong value) => Wait(value);

    internal void Register(object gate)   { lock (_gate) _groups.Add(gate); }
    internal void Unregister(object gate) { lock (_gate) _groups.Remove(gate); }
}
