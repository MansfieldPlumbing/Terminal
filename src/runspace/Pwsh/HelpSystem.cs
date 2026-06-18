using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Subsystem;

public static class HelpSystem
{
    private static Dictionary<string, string>? _helpCache;
    private static readonly object _lock = new();

    public static string GetHelp(string topic)
    {
        lock (_lock)
        {
            if (_helpCache == null)
            {
                _helpCache = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                try
                {
                    // Cmdlet help is provided inline below. (The former pshelp.json embedded resource was
                    // removed; help is being redesigned toward per-capability manifest projection.)
                    // --- Custom Android Cmdlet Help ---
                    _helpCache["Get-AndroidBattery"] = "NAME\n    Get-AndroidBattery\n\nSYNOPSIS\n    Retrieves the current battery status of the Android device.\n\nDESCRIPTION\n    Returns a custom object containing the battery percentage, charging state, health, and temperature.\n\nEXAMPLES\n    PS> Get-AndroidBattery";
                    
                    _helpCache["Get-AndroidDevice"] = "NAME\n    Get-AndroidDevice\n\nSYNOPSIS\n    Retrieves general hardware and OS information about the Android device.\n\nDESCRIPTION\n    Returns details such as the manufacturer, model, OS version, and API level.\n\nEXAMPLES\n    PS> Get-AndroidDevice";
                    
                    _helpCache["Get-AndroidDisplay"] = "NAME\n    Get-AndroidDisplay\n\nSYNOPSIS\n    Retrieves display metrics for the Android device.\n\nDESCRIPTION\n    Returns information about the screen resolution, density, refresh rate, and physical size.\n\nEXAMPLES\n    PS> Get-AndroidDisplay";
                    
                    _helpCache["Get-AndroidMemory"] = "NAME\n    Get-AndroidMemory\n\nSYNOPSIS\n    Retrieves memory (RAM) usage information for the Android device.\n\nDESCRIPTION\n    Returns available and total RAM, as well as threshold states.\n\nEXAMPLES\n    PS> Get-AndroidMemory";
                    
                    _helpCache["Get-AndroidNetwork"] = "NAME\n    Get-AndroidNetwork\n\nSYNOPSIS\n    Retrieves active network connections and interfaces.\n\nDESCRIPTION\n    Returns details about Wi-Fi, Cellular, and other active network interfaces, including IP addresses.\n\nEXAMPLES\n    PS> Get-AndroidNetwork";
                    
                    _helpCache["Get-AndroidStorage"] = "NAME\n    Get-AndroidStorage\n\nSYNOPSIS\n    Retrieves internal storage usage metrics.\n\nDESCRIPTION\n    Returns total space, usable space, and free space on the primary internal storage.\n\nEXAMPLES\n    PS> Get-AndroidStorage";
                    
                    _helpCache["Get-AndroidVolume"] = "NAME\n    Get-AndroidVolume\n\nSYNOPSIS\n    Retrieves volume levels for different audio streams.\n\nDESCRIPTION\n    Returns the current volume percentage for Media, Ring, Alarm, and Notification streams.\n\nEXAMPLES\n    PS> Get-AndroidVolume";
                    
                    _helpCache["Get-InstalledApp"] = "NAME\n    Get-InstalledApp\n\nSYNOPSIS\n    Retrieves a list of installed applications on the Android device.\n\nDESCRIPTION\n    Returns package names and application labels for all installed packages. Can take a long time to run.\n\nEXAMPLES\n    PS> Get-InstalledApp";
                    
                    _helpCache["Show-Toast"] = "NAME\n    Show-Toast\n\nSYNOPSIS\n    Displays a short pop-up message (toast) on the Android device.\n\nSYNTAX\n    Show-Toast [-Message] <string>\n\nDESCRIPTION\n    Shows a temporary floating message on the screen that disappears automatically.\n\nEXAMPLES\n    PS> Show-Toast \"Hello World\"";
                    
                    _helpCache["Send-AndroidNotification"] = "NAME\n    Send-AndroidNotification\n\nSYNOPSIS\n    Pushes a system notification to the Android notification drawer.\n\nSYNTAX\n    Send-AndroidNotification [-Title] <string> [-Text] <string>\n\nDESCRIPTION\n    Creates a persistent system notification with a given title and text content.\n\nEXAMPLES\n    PS> Send-AndroidNotification -Title \"Alert\" -Text \"Task Completed\"";
                    
                    _helpCache["Set-Flashlight"] = "NAME\n    Set-Flashlight\n\nSYNOPSIS\n    Toggles the device's camera flashlight on or off.\n\nSYNTAX\n    Set-Flashlight [-Mode] <string>\n\nDESCRIPTION\n    Mode can be 'On', 'Off', or 'Toggle'. Turns the device's camera LED flash on or off.\n\nEXAMPLES\n    PS> Set-Flashlight \"Toggle\"";
                    
                    _helpCache["Invoke-Beep"] = "NAME\n    Invoke-Beep\n\nSYNOPSIS\n    Plays a short system beep sound.\n\nDESCRIPTION\n    Triggers a standard notification or beep sound through the device's media stream.\n\nEXAMPLES\n    PS> Invoke-Beep";
                }
                catch (Exception ex)
                {
                    return $"Error loading help system: {ex.Message}";
                }
            }

            if (string.IsNullOrEmpty(topic)) return "Usage: Get-Help <topic>";

            topic = topic.Trim();

            // Try exact match
            if (_helpCache.TryGetValue(topic, out var content)) return content;

            // Try with "about_" prefix
            if (!topic.StartsWith("about_", StringComparison.OrdinalIgnoreCase))
            {
                if (_helpCache.TryGetValue("about_" + topic, out content)) return content;
            }

            // Try matching substring/wildcard (like standard Get-Help search)
            var matches = new List<string>();
            foreach (var key in _helpCache.Keys)
            {
                if (key.Contains(topic, StringComparison.OrdinalIgnoreCase))
                {
                    matches.Add(key);
                }
            }

            if (matches.Count == 1)
            {
                return _helpCache[matches[0]];
            }
            else if (matches.Count > 1)
            {
                var sb = new System.Text.StringBuilder();
                sb.AppendLine($"Multiple topics match '{topic}':");
                foreach (var m in matches)
                {
                    sb.AppendLine($"  {m}");
                }
                return sb.ToString();
            }

            return $"Help topic '{topic}' not found.";
        }
    }
}
