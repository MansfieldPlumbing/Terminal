namespace Subsystem;

public class ParserState
{
    public string DefaultFg { get; set; } = "ffffff";
    public string DefaultBg { get; set; } = "000000";

    // Track what is currently active and open in the generated HTML
    public string? CurrentFg { get; set; } = null;
    public string? CurrentBg { get; set; } = null;

    // Track what the ANSI parser currently desires
    public string? DesiredFg { get; set; } = null;
    public string? DesiredBg { get; set; } = null;

    // ANSI parser internal states
    public bool IsBold { get; set; } = false;
    public int? FgCode { get; set; } = null;
    public int? BgCode { get; set; } = null;
    public string? FgExtended { get; set; } = null;
    public string? BgExtended { get; set; } = null;

    public ParserState(string defaultFg = "ffffff", string defaultBg = "000000")
    {
        DefaultFg = defaultFg;
        DefaultBg = defaultBg;
        DesiredFg = defaultFg;
        DesiredBg = defaultBg;
    }
}
