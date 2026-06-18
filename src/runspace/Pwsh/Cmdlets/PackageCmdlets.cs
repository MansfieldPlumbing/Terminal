using System;
using System.Management.Automation;
using Subsystem;

namespace Subsystem.Pwsh.Cmdlets;

[Cmdlet(VerbsData.Update, "PackageInfoDb")]
public sealed class UpdatePackageInfoDbCmdlet : WrapperCmdlet
{
    [Parameter(Position = 0)]
    public string? Url { get; set; }

    protected override void ProcessRecord()
    {
        try
        {
            if (!string.IsNullOrEmpty(Url))
            {
                var result = PackageInfoDb.UpdateFromUrl(Url);
                Emit(result);
            }
            else
            {
                WriteWarning("Package metadata (UAD/Canta, GPL-3.0) is not bundled. Provide -Url to a UAD-shaped JSON to populate the local DB.");
            }
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "UpdatePackageInfoDbFailed", ErrorCategory.InvalidOperation, Url));
        }
    }
}

[Cmdlet(VerbsCommon.Add, "PackageInfo")]
public sealed class AddPackageInfoCmdlet : WrapperCmdlet
{
    [Parameter(ValueFromPipeline = true)]
    public PSObject? InputObject { get; set; }

    protected override void ProcessRecord()
    {
        if (InputObject == null) return;

        try
        {
            string? pkgName = null;
            var propPackage = InputObject.Properties["Package"];
            var propPackageLower = InputObject.Properties["package"];
            var propName = InputObject.Properties["name"];

            if (propPackage?.Value is string p1 && !string.IsNullOrEmpty(p1))
            {
                pkgName = p1;
            }
            else if (propPackageLower?.Value is string p2 && !string.IsNullOrEmpty(p2))
            {
                pkgName = p2;
            }
            else if (propName?.Value is string p3 && !string.IsNullOrEmpty(p3))
            {
                pkgName = p3;
            }

            if (pkgName == null)
            {
                pkgName = propPackage?.Value?.ToString()
                          ?? propPackageLower?.Value?.ToString()
                          ?? propName?.Value?.ToString();
            }

            PackageInfo? info = null;
            if (!string.IsNullOrEmpty(pkgName))
            {
                info = PackageInfoDb.Lookup(pkgName);
            }

            string? desc = info?.Description;
            string removal = info?.Removal ?? "Unknown";
            if (string.IsNullOrEmpty(removal)) removal = "Unknown";
            string? source = info?.List;

            SetProperty(InputObject, "Description", desc);
            SetProperty(InputObject, "Removal", removal);
            SetProperty(InputObject, "Source", source);

            Emit(InputObject);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "AddPackageInfoFailed", ErrorCategory.InvalidOperation, InputObject));
        }
    }

    private static void SetProperty(PSObject obj, string name, object? value)
    {
        var prop = obj.Properties[name];
        if (prop != null)
        {
            prop.Value = value;
        }
        else
        {
            obj.Properties.Add(new PSNoteProperty(name, value));
        }
    }
}
