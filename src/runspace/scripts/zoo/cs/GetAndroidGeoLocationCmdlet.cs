using System.Management.Automation;
using Android.Locations;
using Android.Content;
using System.Collections.Generic;
using Subsystem.Pwsh.Cmdlets;

namespace Subsystem.Pwsh.Cmdlets.Zoo;

[Cmdlet(VerbsCommon.Get, "AndroidGeoLocation")]
public sealed class GetAndroidGeoLocationCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        var dict = new Dictionary<string, object>();
        try
        {
            var ctx = Android.App.Application.Context;
            var lm = (LocationManager?)ctx.GetSystemService(Context.LocationService);
            if (lm != null)
            {
                var criteria = new Criteria { Accuracy = Accuracy.Coarse };
                var provider = lm.GetBestProvider(criteria, enabledOnly: true) ?? LocationManager.GpsProvider;
                var loc = lm.GetLastKnownLocation(provider);
                if (loc != null)
                {
                    dict["Latitude"] = loc.Latitude;
                    dict["Longitude"] = loc.Longitude;
                    dict["Altitude"] = loc.Altitude;
                    dict["Accuracy"] = loc.Accuracy;
                    dict["Provider"] = loc.Provider ?? "Unknown";
                    dict["TimeMs"] = loc.Time;
                }
                else
                {
                    dict["Error"] = "No last known location available.";
                }
            }
            else
            {
                dict["Error"] = "LocationManager service not available.";
            }
        }
        catch (System.Exception ex)
        {
            dict["Error"] = ex.Message;
        }
        Emit(dict);
    }
}
