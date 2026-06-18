using System.Text;

namespace Subsystem;

public static class Translator
{
    private static readonly string[] StandardColors = 
    [
        "000000", // 0: Black
        "800000", // 1: Red
        "008000", // 2: Green
        "808000", // 3: Yellow
        "000080", // 4: Blue
        "800080", // 5: Magenta
        "008080", // 6: Cyan
        "c0c0c0"  // 7: White
    ];

    private static readonly string[] BrightColors = 
    [
        "808080", // 8: Bright Black (Gray)
        "ff0000", // 9: Bright Red
        "00ff00", // 10: Bright Green
        "ffff00", // 11: Bright Yellow
        "0000ff", // 12: Bright Blue
        "ff00ff", // 13: Bright Magenta
        "00ffff", // 14: Bright Cyan
        "ffffff"  // 15: Bright White
    ];

    private static readonly int[] CubeSteps = [0, 95, 135, 175, 223, 255];

    public static string Translate(string input, string defaultFg = "ffffff", string defaultBg = "000000")
    {
        var state = new ParserState(defaultFg, defaultBg);
        return Translate(input, state);
    }

    public static string Translate(string input, ParserState state)
    {
        var sb = new StringBuilder();
        sb.AppendLine("<div class=\"ansi-output\" style=\"background-color:#" + state.DefaultBg + "; color:#" + state.DefaultFg + ";\">");

        int i = 0;
        int len = input.Length;

        while (i < len)
        {
            char c = input[i];

            if (c == '\u001b')
            {
                if (i + 1 < len && input[i + 1] == '[')
                {
                    // Control Sequence Introducer (CSI)
                    i += 2;
                    var seqBuilder = new StringBuilder();
                    char terminator = '\0';

                    while (i < len)
                    {
                        char seqChar = input[i];
                        if ((seqChar >= 'a' && seqChar <= 'z') || (seqChar >= 'A' && seqChar <= 'Z'))
                        {
                            terminator = seqChar;
                            i++;
                            break;
                        }
                        seqBuilder.Append(seqChar);
                        i++;
                    }

                    if (terminator == 'm')
                    {
                        // Select Graphic Rendition (SGR)
                        ProcessSgr(seqBuilder.ToString(), state);
                    }
                    // Non-SGR escape sequences (cursor movements, clear screen, etc.) are safely bypassed
                    continue;
                }
                else
                {
                    // Escape sequence that is not CSI is skipped to keep output clean
                    i++;
                    continue;
                }
            }

            // Before writing any normal text, reconcile current tag state to match the ANSI-desired color state
            ReconcileTags(sb, state);

            // Escape HTML characters
            if (c == '<') sb.Append("&lt;");
            else if (c == '>') sb.Append("&gt;");
            else if (c == '&') sb.Append("&amp;");
            else sb.Append(c);

            i++;
        }

        // Close outstanding open tags before closing document
        CloseActiveTags(sb, state);

        sb.AppendLine("</div>");

        return sb.ToString();
    }

    private static void ProcessSgr(string seq, ParserState state)
    {
        if (string.IsNullOrEmpty(seq))
        {
            ResetState(state);
            return;
        }

        string[] parts = seq.Split(';');
        int idx = 0;

        while (idx < parts.Length)
        {
            if (!int.TryParse(parts[idx], out int code))
            {
                idx++;
                continue;
            }

            switch (code)
            {
                case 0:
                    ResetState(state);
                    break;
                case 1:
                    state.IsBold = true;
                    UpdateDesiredColors(state);
                    break;
                case 22:
                    state.IsBold = false;
                    UpdateDesiredColors(state);
                    break;
                case >= 30 and <= 37:
                    state.FgCode = code;
                    state.FgExtended = null;
                    UpdateDesiredColors(state);
                    break;
                case 38:
                    // Extended Foreground Color
                    if (idx + 1 < parts.Length && int.TryParse(parts[idx + 1], out int fgMode))
                    {
                        if (fgMode == 5 && idx + 2 < parts.Length) // 8-bit
                        {
                            if (int.TryParse(parts[idx + 2], out int colorIdx))
                            {
                                state.FgExtended = Get8BitColor(colorIdx);
                                idx += 2;
                                UpdateDesiredColors(state);
                            }
                        }
                        else if (fgMode == 2 && idx + 4 < parts.Length) // 24-bit RGB
                        {
                            if (int.TryParse(parts[idx + 2], out int r) &&
                                int.TryParse(parts[idx + 3], out int g) &&
                                int.TryParse(parts[idx + 4], out int b))
                            {
                                state.FgExtended = $"{r:X2}{g:X2}{b:X2}".ToLower();
                                idx += 4;
                                UpdateDesiredColors(state);
                            }
                        }
                    }
                    break;
                case 39:
                    state.FgCode = null;
                    state.FgExtended = null;
                    UpdateDesiredColors(state);
                    break;
                case >= 40 and <= 47:
                    state.BgCode = code;
                    state.BgExtended = null;
                    UpdateDesiredColors(state);
                    break;
                case 48:
                    // Extended Background Color
                    if (idx + 1 < parts.Length && int.TryParse(parts[idx + 1], out int bgMode))
                    {
                        if (bgMode == 5 && idx + 2 < parts.Length) // 8-bit
                        {
                            if (int.TryParse(parts[idx + 2], out int colorIdx))
                            {
                                state.BgExtended = Get8BitColor(colorIdx);
                                idx += 2;
                                UpdateDesiredColors(state);
                            }
                        }
                        else if (bgMode == 2 && idx + 4 < parts.Length) // 24-bit RGB
                        {
                            if (int.TryParse(parts[idx + 2], out int r) &&
                                int.TryParse(parts[idx + 3], out int g) &&
                                int.TryParse(parts[idx + 4], out int b))
                            {
                                state.BgExtended = $"{r:X2}{g:X2}{b:X2}".ToLower();
                                idx += 4;
                                UpdateDesiredColors(state);
                            }
                        }
                    }
                    break;
                case 49:
                    state.BgCode = null;
                    state.BgExtended = null;
                    UpdateDesiredColors(state);
                    break;
                case >= 90 and <= 97:
                    state.FgCode = code;
                    state.FgExtended = null;
                    UpdateDesiredColors(state);
                    break;
                case >= 100 and <= 107:
                    state.BgCode = code;
                    state.BgExtended = null;
                    UpdateDesiredColors(state);
                    break;
            }

            idx++;
        }
    }

    private static void UpdateDesiredColors(ParserState state)
    {
        // Resolve Foreground
        if (state.FgExtended != null)
        {
            state.DesiredFg = state.FgExtended;
        }
        else if (state.FgCode.HasValue)
        {
            int code = state.FgCode.Value;
            if (code >= 30 && code <= 37)
            {
                int colorIdx = code - 30;
                state.DesiredFg = state.IsBold ? BrightColors[colorIdx] : StandardColors[colorIdx];
            }
            else if (code >= 90 && code <= 97)
            {
                int colorIdx = code - 90;
                state.DesiredFg = BrightColors[colorIdx];
            }
            else
            {
                state.DesiredFg = state.DefaultFg;
            }
        }
        else
        {
            state.DesiredFg = state.DefaultFg;
        }

        // Resolve Background
        if (state.BgExtended != null)
        {
            state.DesiredBg = state.BgExtended;
        }
        else if (state.BgCode.HasValue)
        {
            int code = state.BgCode.Value;
            if (code >= 40 && code <= 47)
            {
                int colorIdx = code - 40;
                state.DesiredBg = StandardColors[colorIdx];
            }
            else if (code >= 100 && code <= 107)
            {
                int colorIdx = code - 100;
                state.DesiredBg = BrightColors[colorIdx];
            }
            else
            {
                state.DesiredBg = state.DefaultBg;
            }
        }
        else
        {
            state.DesiredBg = state.DefaultBg;
        }
    }

    private static void ResetState(ParserState state)
    {
        state.IsBold = false;
        state.FgCode = null;
        state.BgCode = null;
        state.FgExtended = null;
        state.BgExtended = null;
        state.DesiredFg = state.DefaultFg;
        state.DesiredBg = state.DefaultBg;
    }

    private static void ReconcileTags(StringBuilder sb, ParserState state)
    {
        bool bgChanged = state.DesiredBg != state.CurrentBg;
        bool fgChanged = state.DesiredFg != state.CurrentFg;

        if (bgChanged || fgChanged)
        {
            // Close the foreground tag first, as it is nested inside the background tag
            if (state.CurrentFg != null)
            {
                sb.Append("</span>");
                state.CurrentFg = null;
            }

            // Close the background tag next, only if the background actually changed
            if (bgChanged && state.CurrentBg != null)
            {
                sb.Append("</span>");
                state.CurrentBg = null;
            }

            // Open the new background tag if it changed and is non-null
            if (bgChanged && state.DesiredBg != null)
            {
                sb.Append($"<span style=\"background-color:#{state.DesiredBg};\">");
                state.CurrentBg = state.DesiredBg;
            }

            // Open the new foreground tag if it is non-null
            if (state.DesiredFg != null)
            {
                sb.Append($"<span style=\"color:#{state.DesiredFg};\">");
                state.CurrentFg = state.DesiredFg;
            }
        }
    }

    private static void CloseActiveTags(StringBuilder sb, ParserState state)
    {
        if (state.CurrentFg != null)
        {
            sb.Append("</span>");
            state.CurrentFg = null;
        }
        if (state.CurrentBg != null)
        {
            sb.Append("</span>");
            state.CurrentBg = null;
        }
    }

    private static string Get8BitColor(int index)
    {
        if (index < 0 || index > 255) return "ffffff";

        if (index < 8)
        {
            return StandardColors[index];
        }
        if (index < 16)
        {
            return BrightColors[index - 8];
        }
        if (index < 232)
        {
            // 6x6x6 color cube step algorithm
            int r = CubeSteps[(index - 16) / 36];
            int g = CubeSteps[((index - 16) % 36) / 6];
            int b = CubeSteps[(index - 16) % 6];
            return $"{r:X2}{g:X2}{b:X2}".ToLower();
        }

        // Grayscale ramp calculation
        int gray = 8 + (index - 232) * 10;
        return $"{gray:X2}{gray:X2}{gray:X2}".ToLower();
    }
}
