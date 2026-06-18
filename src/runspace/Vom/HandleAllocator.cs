using System;
using System.Collections.Generic;

namespace Subsystem.Vom;

// Generational slot table (VOM-SPEC §4; prior-art §7.3). A handle id is [16-bit generation | 16-bit
// index]. Free() bumps the slot's generation so any stale handle fails IsValid() in O(1) — solving
// use-after-free / ABA before the first driver mounts. Slots are reused via a free list; generation
// rolls forward. Lock-based for Phase 1 (the lock-free data-plane fast path is later). Max 65,535
// live handles per owner (the 16-bit index); tunable later via the gen/index split.
public sealed class HandleAllocator
{
    private HandleEntry?[] _slots = new HandleEntry?[64];
    private ushort[]       _gen   = new ushort[64];
    private bool[]         _live  = new bool[64];
    private readonly Stack<int> _free = new();
    private int _high = 1;                        // index 0 reserved -> id 0 is the null handle
    private readonly object _lock = new();

    public const uint Null = 0;

    public int LiveCount { get { lock (_lock) { return (_high - 1) - _free.Count; } } }

    internal uint Allocate(HandleEntry entry)
    {
        lock (_lock)
        {
            int idx = _free.Count > 0 ? _free.Pop() : _high++;
            if (idx >= _slots.Length) Grow(idx);
            if (_gen[idx] == 0) _gen[idx] = 1;   // generations start at 1
            _slots[idx] = entry;
            _live[idx]  = true;
            return ((uint)_gen[idx] << 16) | (uint)idx;
        }
    }

    internal bool Free(uint id, out HandleEntry? entry)
    {
        lock (_lock)
        {
            int idx = (int)(id & 0xFFFF);
            if (!LiveLocked(id, idx)) { entry = null; return false; }
            entry = _slots[idx];
            _slots[idx] = null;
            _live[idx]  = false;
            _gen[idx]++;                          // bump => every stale id for this slot now invalid
            if (_gen[idx] == 0) _gen[idx] = 1;    // skip 0 on wrap
            _free.Push(idx);
            return true;
        }
    }

    internal bool TryGet(uint id, out HandleEntry? entry)
    {
        lock (_lock)
        {
            int idx = (int)(id & 0xFFFF);
            if (LiveLocked(id, idx)) { entry = _slots[idx]; return true; }
            entry = null; return false;
        }
    }

    public bool IsValid(uint id) { lock (_lock) { return LiveLocked(id, (int)(id & 0xFFFF)); } }

    private bool LiveLocked(uint id, int idx)
        => idx > 0 && idx < _high && _live[idx] && _gen[idx] == (ushort)(id >> 16);

    private void Grow(int needed)
    {
        int n = _slots.Length;
        while (n <= needed) n <<= 1;
        Array.Resize(ref _slots, n);
        Array.Resize(ref _gen,   n);
        Array.Resize(ref _live,  n);
    }
}
