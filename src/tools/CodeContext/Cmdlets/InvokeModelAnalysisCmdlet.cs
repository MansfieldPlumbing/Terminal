using System;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Subsystem.Tools.CodeContext.Cmdlets;

[Cmdlet(VerbsLifecycle.Invoke, "ModelAnalysis")]
public class InvokeModelAnalysisCmdlet : PSCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string FilePath { get; set; } = string.Empty;

    [Parameter(Mandatory = false)]
    [ValidateSet("Sentinel", "Anchor", "Carver", "IEEE754")]
    public string Mode { get; set; } = "Sentinel";

    [Parameter(Mandatory = false)]
    public long WeightBase { get; set; } = 0x00081000;

    protected override void ProcessRecord()
    {
        string fullPath = Path.GetFullPath(FilePath);
        if (!File.Exists(fullPath))
        {
            ThrowTerminatingError(new ErrorRecord(new FileNotFoundException(), "FileNotFound", ErrorCategory.ObjectNotFound, FilePath));
        }

        try
        {
            byte[] fileBytes = File.ReadAllBytes(fullPath);
            int length = fileBytes.Length;

            switch (Mode.ToLowerInvariant())
            {
                case "sentinel":
                    RunSentinelScan(fileBytes, length);
                    break;
                case "anchor":
                    RunAnchorScan(fileBytes, length);
                    break;
                case "carver":
                    RunCarverScan(fileBytes, length);
                    break;
                case "ieee754":
                    RunIeeeScan(fileBytes, length);
                    break;
            }
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "ScanFailed", ErrorCategory.InvalidOperation, fullPath));
        }
    }

    private void RunSentinelScan(byte[] bytes, int length)
    {
        // Sentinel value: 0xC0000001 (uint32, little-endian)
        // We need at least 12 bytes before (Pre3, Pre2, Pre1) and 20 bytes after (Size, F1, F2, F3)
        // Struct size = 32 bytes total
        uint sentinel = 0xC0000001;

        var results = new List<object>();

        for (int i = 12; i < length - 20; i += 4)
        {
            uint val = BitConverter.ToUInt32(bytes, i);
            if (val == sentinel)
            {
                int pre3 = BitConverter.ToInt32(bytes, i - 12);
                int pre2 = BitConverter.ToInt32(bytes, i - 8);
                int pre1 = BitConverter.ToInt32(bytes, i - 4);
                uint size = BitConverter.ToUInt32(bytes, i + 4);
                uint f1 = BitConverter.ToUInt32(bytes, i + 8);
                uint f2 = BitConverter.ToUInt32(bytes, i + 12);
                uint f3 = BitConverter.ToUInt32(bytes, i + 16);

                string classification = "UNKNOWN";
                long physicalOffset = WeightBase + f1;

                if (physicalOffset >= WeightBase && physicalOffset < length)
                {
                    classification = "WEIGHT_PTR";
                }
                else if (f1 < 0x10000 || f1 == 8)
                {
                    classification = "TENSOR_REF";
                }

                results.Add(new
                {
                    Offset = i,
                    Pre3 = pre3,
                    Pre2 = pre2,
                    Pre1 = pre1,
                    Sentinel = $"0x{val:X}",
                    Size = size,
                    Field1 = f1,
                    Field2 = f2,
                    Field3 = f3,
                    Classification = classification
                });
            }
        }

        WriteObject(results.ToArray(), true);
    }

    private void RunAnchorScan(byte[] bytes, int length)
    {
        // Anchor mode: scans for structures where TypeFlag == 3
        // Struct: Word 0 = Pointer (uint32), Word 3 = Logical Size (uint32)
        var results = new List<object>();

        // Sweep in 16-byte structure strides
        for (int i = 0; i < length - 16; i += 16)
        {
            uint typeFlag = BitConverter.ToUInt32(bytes, i + 8); // Assuming TypeFlag is offset 8
            if (typeFlag == 3)
            {
                uint ptr = BitConverter.ToUInt32(bytes, i);
                uint size = BitConverter.ToUInt32(bytes, i + 12);
                long physicalOffset = WeightBase + ptr;

                if (physicalOffset >= WeightBase && physicalOffset < length)
                {
                    results.Add(new
                    {
                        StructOffset = i,
                        VirtualPointer = $"0x{ptr:X}",
                        PhysicalOffset = $"0x{physicalOffset:X}",
                        LogicalSize = size,
                        TypeFlag = typeFlag
                    });
                }
            }
        }

        WriteObject(results.ToArray(), true);
    }

    private void RunCarverScan(byte[] bytes, int length)
    {
        // Carver mode: checks layout chains using the Carver equation
        // NextPointer = CurrentPointer + CurrentSize + PaddingGap (PaddingGap <= 8192)
        var results = new List<object>();

        // Scan the binary for contiguous pointer chains
        for (int i = 0; i < length - 64; i += 4)
        {
            uint ptr1 = BitConverter.ToUInt32(bytes, i);
            uint size1 = BitConverter.ToUInt32(bytes, i + 4);
            uint ptr2 = BitConverter.ToUInt32(bytes, i + 16); // Assuming 16-byte stride
            uint size2 = BitConverter.ToUInt32(bytes, i + 20);

            if (ptr1 > 0 && size1 > 0 && ptr2 > ptr1)
            {
                long gap = (long)ptr2 - (ptr1 + size1);
                if (gap >= 0 && gap <= 8192)
                {
                    results.Add(new
                    {
                        Offset = i,
                        CurrentPointer = $"0x{ptr1:X}",
                        CurrentSize = size1,
                        NextPointer = $"0x{ptr2:X}",
                        NextSize = size2,
                        PaddingGap = gap
                    });
                }
            }
        }

        WriteObject(results.ToArray(), true);
    }

    private void RunIeeeScan(byte[] bytes, int length)
    {
        // IEEE754 scale scanning: sign == 0 && exp >= 100 && exp <= 130
        var results = new List<object>();

        for (int i = 0; i < length - 4; i += 4)
        {
            uint bits = BitConverter.ToUInt32(bytes, i);
            uint exp = (bits >> 23) & 0xFF;
            uint sign = bits >> 31;

            if (sign == 0 && exp >= 100 && exp <= 130)
            {
                float val = BitConverter.ToSingle(bytes, i);
                if (val > 1e-5f && val < 5.0f)
                {
                    results.Add(new
                    {
                        Offset = i,
                        HexValue = $"0x{bits:X}",
                        FloatValue = val,
                        Exponent = exp
                    });
                }
            }
        }

        WriteObject(results.ToArray(), true);
    }
}
