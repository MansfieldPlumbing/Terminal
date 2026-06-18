using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Management.Automation.Language;
using System.Management.Automation.Runspaces;

namespace Subsystem {
    public static class SubsystemAliases {

        // The shell-convenience functions live as DATA in a shipped .ps1 asset (User tier), never as
        // string literals in this file (SS001). Loaded into the ISS so every runspace inherits them.
        private const string ShellFunctionsAsset = "shell/cli/shell-functions.ps1";

        public static readonly (string Alias, string Target)[] CoreMappings = new[] {
            ("sl", "Set-Location"), ("chdir", "Set-Location"), ("pwd", "Get-Location"),
            ("pushd", "Push-Location"), ("popd", "Pop-Location"), ("ls", "Get-ChildItem"), ("dir", "Get-ChildItem"),
            ("gci", "Get-ChildItem"), ("cat", "Get-Content"), ("type", "Get-Content"), ("gc", "Get-Content"),
            ("echo", "Write-Output"), ("write", "Write-Output"), ("cp", "Copy-Item"), ("copy", "Copy-Item"),
            ("cpi", "Copy-Item"), ("mv", "Move-Item"), ("move", "Move-Item"), ("mi", "Move-Item"),
            ("rm", "Remove-Item"), ("del", "Remove-Item"), ("rd", "Remove-Item"), ("ri", "Remove-Item"),
            ("rmdir", "Remove-Item"), ("erase", "Remove-Item"), ("ren", "Rename-Item"), ("rni", "Rename-Item"), 
            ("h", "Get-History"), ("history", "Get-History"), 
            ("ghy", "Get-History"), ("clhy", "Clear-History"), ("man", "Get-Help"), ("help", "Get-Help"), 
            ("gip", "Get-Help"), ("which", "Get-Command"), ("gcm", "Get-Command"), ("ps", "Get-Process"), 
            ("gps", "Get-Process"), ("kill", "Stop-Process"), ("sps", "Stop-Process"), ("grep", "Select-String"), 
            ("sls", "Select-String"), ("sort", "Sort-Object"), ("tee", "Tee-Object"), ("diff", "Compare-Object"), 
            ("compare", "Compare-Object"), ("measure", "Measure-Object"), ("curl", "Invoke-WebRequest"), 
            ("wget", "Invoke-WebRequest"), ("iwr", "Invoke-WebRequest"), ("irm", "Invoke-RestMethod"), 
            ("alias", "Get-Alias"), ("gal", "Get-Alias"), ("sal", "Set-Alias"),
            ("foreach", "ForEach-Object"), ("%", "ForEach-Object"), 
            ("where", "Where-Object"), ("?", "Where-Object"), ("select", "Select-Object")
        };

        public static void Load(InitialSessionState iss) {
            foreach (var mapping in CoreMappings) iss.Commands.Add(new SessionStateAliasEntry(mapping.Alias, mapping.Target, ""));

            LoadShellFunctions(iss);
            LoadZoo(iss);

            // Every compiled cmdlet registers itself by its [Cmdlet] attribute — the attribute IS the
            // registration truth (NT: a capability advertises itself), so no hand-maintained parallel list
            // can drift. This replaced an explicit per-cmdlet list whose entries silently dropped at
            // runspace open; Import-Module -Assembly (attribute-based, exactly like this) always worked.
            Type[] cmdletTypes;
            try { cmdletTypes = typeof(SubsystemAliases).Assembly.GetTypes(); }
            catch (ReflectionTypeLoadException ex) { cmdletTypes = ex.Types.Where(t => t != null).ToArray()!; }
            foreach (var type in cmdletTypes) {
                var attr = type.GetCustomAttribute<System.Management.Automation.CmdletAttribute>();
                if (attr != null)
                    iss.Commands.Add(new SessionStateCmdletEntry($"{attr.VerbName}-{attr.NounName}", type, null));
            }
        }

        // THE ZOO LOADER (the long-owed runtime half of the .ps1 cmdlet doctrine): every shipped
        // zoo/*.ps1 asset becomes a function named for its file (New-Card.ps1 → New-Card). The script
        // text IS the function body — a `[CmdletBinding()] param(...)` script is a valid body verbatim,
        // so one file = one User-tier script cmdlet, never a .cs string (SS001). A script that fails to
        // parse is skipped + reported (SS007) — one bad animal never closes the zoo.
        private static void LoadZoo(InitialSessionState iss) {
            try {
                var assets = Android.App.Application.Context.Assets;
                var files = assets?.List("zoo") ?? Array.Empty<string>();
                foreach (var f in files) {
                    if (!f.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase)) continue;
                    try {
                        using var s = assets!.Open("zoo/" + f);
                        using var rd = new StreamReader(s);
                        var text = rd.ReadToEnd();
                        Parser.ParseInput(text, out _, out var errs);
                        if (errs is { Length: > 0 }) { Dg.Log("alias", $"zoo {f} parse: {errs[0].Message}"); continue; }
                        iss.Commands.Add(new SessionStateFunctionEntry(Path.GetFileNameWithoutExtension(f), text));
                    } catch (System.Exception exf) { Dg.Log("alias", $"zoo {f} load failed: {exf.Message}"); }
                }
            } catch (System.Exception ex) { Dg.Log("alias", "zoo load failed: " + ex.Message); }
        }

        // Parse the shipped shell-functions asset and register each function in the ISS. The body text
        // comes from the FILE (not a .cs literal), so the convenience shims stay User-tier DATA — the
        // SS001-clean home for a script. Degrades + reports to Dg on any failure (SS007); the shell
        // still works without the muscle-memory shims.
        private static void LoadShellFunctions(InitialSessionState iss) {
            string text;
            try {
                text = ObpHost.ReadAllText(ShellFunctionsAsset)
                    ?? throw new FileNotFoundException(ShellFunctionsAsset);
            } catch (System.Exception ex) {
                Dg.Log("alias", $"shell-functions '{ShellFunctionsAsset}' unreadable: {ex.Message}");
                return;
            }

            var ast = Parser.ParseInput(text, out _, out var errors);
            if (errors is { Length: > 0 }) {
                Dg.Log("alias", $"shell-functions parse: {errors.Length} error(s), first: {errors[0].Message}");
                return;
            }

            foreach (var fn in ast.FindAll(n => n is FunctionDefinitionAst, searchNestedScriptBlocks: false).Cast<FunctionDefinitionAst>()) {
                // FunctionDefinitionAst.Body.Extent is the brace-wrapped script block; SessionStateFunctionEntry
                // wants the body WITHOUT the outer braces (matching how these were authored inline before).
                string body = fn.Body.Extent.Text.Trim();
                if (body.StartsWith("{")) body = body.Substring(1);
                if (body.EndsWith("}"))   body = body.Substring(0, body.Length - 1);
                iss.Commands.Add(new SessionStateFunctionEntry(fn.Name, body));
            }
        }
    }
}
