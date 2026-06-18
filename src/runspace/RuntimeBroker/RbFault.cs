using System;

namespace Subsystem.RuntimeBroker
{
    // §3.1 — the inference subsystem's typed fault surface. Interior code branches on Class ONLY;
    // NativeDetail is opaque payload (journal/UI) and is interpreted nowhere past the JNI boundary.
    public enum RbFaultClass
    {
        AdmissionRefused,      // §4: budget evaluation refused every requested backend
        BringUpFailed,         // engine/conversation construction failed on all admitted rungs
        VerificationFailed,    // §6(d): bring-up reported success but the liveness check failed
        EngineReclaimed,       // the engine object was rundown (model switch, trim, teardown)
        ConversationDefunct,   // native conversation not serviceable
        DecodeCancelled,       // in-flight decode interrupted via CancelProcess
        DecodeFaulted,         // native decode error other than cancellation
        BackendUnavailable,    // requested backend absent on this device (no OpenCL/NPU runtime)
    }

    public sealed record RbFault(RbFaultClass Class, string UnitId, string Backend, string NativeDetail);

    // Carrier for the fault record across throw boundaries. Message is for logs; consumers use Fault.
    public sealed class RbFaultException : Exception
    {
        public RbFault Fault { get; }
        public RbFaultException(RbFault fault)
            : base($"{fault.Class} [{fault.UnitId}/{fault.Backend}] {fault.NativeDetail}")
            => Fault = fault;
    }
}
