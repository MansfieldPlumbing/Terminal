using System;

namespace Subsystem.Cm;

// A registered capability/cmdlet record (VOM-SPEC §6 "Cmdlets"). The ManifestJson is simultaneously the
// agent/FunctionGemma tool schema, the UI widget type, AND the permission surface (§6a) — one JSON, N
// consumers. DependsOn = the grant / late-bind / revocation dependency graph (§6). Integrity is the
// service account (System/Admin/User/Untrusted); StartType + Enabled are the SCM-style lifecycle the Sc
// services layer and the rocker toggles ride on.
public sealed class CapabilityRecord
{
    public string  Path        { get; set; } = "";          // PK, e.g. \Capability\Projection
    public string  Name        { get; set; } = "";
    public string  Type        { get; set; } = "Capability";// Capability | Cmdlet | Mount | Service | Probe
    public string? Source      { get; set; }                // .ps1 / scriptblock text, re-loadable
    public string? ManifestJson{ get; set; }                // verbs/params/widget/permission
    public string  Owner       { get; set; } = "\\System";
    public string  Integrity   { get; set; } = "User";      // System | Admin | User | Untrusted
    public string  StartType   { get; set; } = "manual";    // auto | manual | disabled
    public bool    Enabled     { get; set; }
    public string[] DependsOn  { get; set; } = Array.Empty<string>();
    public string  Created     { get; set; } = "";
    public string  Modified    { get; set; } = "";
    public string  Hash        { get; set; } = "";
}
