using System;

namespace Subsystem.Device;

// \Device\Android\* introspection drivers — decomposed VERBATIM from the VirtualObjectManager god-object
// (VOM-SPEC §1: device capabilities are drivers, not kernel/host methods). Bodies are unchanged; only the
// containing type moved. Each class maps to one \Device\Android\<X> mount.

// \Device\Android\Power
public static class Power
{
    public static System.Collections.Generic.Dictionary<string, object> GetBatteryStatus()
    {
        var dict = new System.Collections.Generic.Dictionary<string, object>();
        try {
            var ctx = Android.App.Application.Context;
            using var bm = (Android.OS.BatteryManager?)ctx.GetSystemService(Android.Content.Context.BatteryService);
            if (bm != null) {
                dict["Level"] = bm.GetIntProperty((int)Android.OS.BatteryProperty.Capacity);

                using var filter = new Android.Content.IntentFilter(Android.Content.Intent.ActionBatteryChanged);
                using var batteryStatus = ctx.RegisterReceiver(null, filter);
                if (batteryStatus != null) {
                    int status = batteryStatus.GetIntExtra(Android.OS.BatteryManager.ExtraStatus, -1);
                    bool isCharging = status == (int)Android.OS.BatteryStatus.Charging || status == (int)Android.OS.BatteryStatus.Full;
                    dict["IsCharging"] = isCharging;
                    dict["Temperature"] = batteryStatus.GetIntExtra(Android.OS.BatteryManager.ExtraTemperature, 0) / 10.0;
                    dict["Voltage"] = batteryStatus.GetIntExtra(Android.OS.BatteryManager.ExtraVoltage, 0);
                    dict["Technology"] = batteryStatus.GetStringExtra(Android.OS.BatteryManager.ExtraTechnology) ?? "Unknown";
                }
            }
        } catch (Exception ex) { Dg.Warn("power", ex); }
        return dict;
    }
}

// \Device\Android\Info
public static class Info
{
    public static System.Collections.Generic.Dictionary<string, object> GetDeviceInfo()
    {
        return new System.Collections.Generic.Dictionary<string, object>
        {
            ["Model"] = Android.OS.Build.Model ?? "Unknown",
            ["Manufacturer"] = Android.OS.Build.Manufacturer ?? "Unknown",
            ["Device"] = Android.OS.Build.Device ?? "Unknown",
            ["Board"] = Android.OS.Build.Board ?? "Unknown",
            ["Hardware"] = Android.OS.Build.Hardware ?? "Unknown",
            ["OSVersion"] = Android.OS.Build.VERSION.Release ?? "Unknown",
            ["SdkInt"] = (int)Android.OS.Build.VERSION.SdkInt,
            ["IsEmulator"] = Android.OS.Build.Fingerprint?.Contains("generic") ?? false
        };
    }
}

// \Device\Android\Storage
public static class Storage
{
    public static System.Collections.Generic.Dictionary<string, object> GetStorageInfo()
    {
        var dict = new System.Collections.Generic.Dictionary<string, object>();
        try {
            using var dataDir = Android.OS.Environment.DataDirectory;
            var path = dataDir?.Path ?? "/data";
            using var stat = new Android.OS.StatFs(path);
            long blockSize = stat.BlockSizeLong;
            long total = stat.BlockCountLong * blockSize;
            long free = stat.AvailableBlocksLong * blockSize;
            dict["TotalBytes"] = total;
            dict["FreeBytes"] = free;
            dict["UsedBytes"] = total - free;
            dict["TotalGB"] = System.Math.Round(total / 1073741824.0, 2);
            dict["FreeGB"] = System.Math.Round(free / 1073741824.0, 2);
        } catch (Exception ex) { Dg.Warn("storage", ex); }
        return dict;
    }
}

// \Device\Android\Memory
public static class Memory
{
    public static System.Collections.Generic.Dictionary<string, object> GetMemoryInfo()
    {
        var dict = new System.Collections.Generic.Dictionary<string, object>();
        try {
            var ctx = Android.App.Application.Context;
            using var am = (Android.App.ActivityManager?)ctx.GetSystemService(Android.Content.Context.ActivityService);
            if (am != null) {
                using var mi = new Android.App.ActivityManager.MemoryInfo();
                am.GetMemoryInfo(mi);
                dict["TotalBytes"] = mi.TotalMem;
                dict["AvailableBytes"] = mi.AvailMem;
                dict["UsedBytes"] = mi.TotalMem - mi.AvailMem;
                dict["LowMemory"] = mi.LowMemory;
                dict["ThresholdBytes"] = mi.Threshold;
                dict["TotalGB"] = System.Math.Round(mi.TotalMem / 1073741824.0, 2);
            }
        } catch (Exception ex) { Dg.Warn("memory", ex); }
        return dict;
    }
}

// \Device\Android\Sensors
public static class Sensors
{
    public static System.Collections.Generic.List<System.Collections.Generic.Dictionary<string, object>> GetSensors()
    {
        var list = new System.Collections.Generic.List<System.Collections.Generic.Dictionary<string, object>>();
        try {
            var ctx = Android.App.Application.Context;
            using var sm = (Android.Hardware.SensorManager?)ctx.GetSystemService(Android.Content.Context.SensorService);
            var sensors = sm?.GetSensorList(Android.Hardware.SensorType.All);
            if (sensors != null) {
                foreach (var s in sensors) {
                    var d = new System.Collections.Generic.Dictionary<string, object>();
                    d["Name"] = s.Name ?? "";
                    d["Type"] = s.Type.ToString();
                    d["Vendor"] = s.Vendor ?? "";
                    d["Version"] = s.Version;
                    d["Power"] = s.Power;
                    d["MaximumRange"] = s.MaximumRange;
                    list.Add(d);
                    s.Dispose(); // Dispose the individual sensor wrappers
                }
            }
        } catch (Exception ex) { Dg.Warn("sensors", ex); }
        return list;
    }
}

// \Device\Android\Network
public static class Network
{
    public static System.Collections.Generic.Dictionary<string, object> GetNetworkInfo() {
        var d = new System.Collections.Generic.Dictionary<string, object>();
        try {
            var ctx = Android.App.Application.Context;
            var cm = (Android.Net.ConnectivityManager?)ctx.GetSystemService(Android.Content.Context.ConnectivityService);
            if (cm != null) {
                var nc = cm.GetNetworkCapabilities(cm.ActiveNetwork);
                d["IsConnected"] = nc != null;
                if (nc != null) {
                    d["HasWiFi"] = nc.HasTransport(Android.Net.TransportType.Wifi);
                    d["HasCellular"] = nc.HasTransport(Android.Net.TransportType.Cellular);
                    d["HasVpn"] = nc.HasTransport(Android.Net.TransportType.Vpn);
                    d["DownstreamKbps"] = nc.LinkDownstreamBandwidthKbps;
                    d["UpstreamKbps"] = nc.LinkUpstreamBandwidthKbps;
                }
            }
        } catch (Exception ex) { Dg.Warn("network", ex); }
        return d;
    }
}
