# Mission: UI Refactoring through Algebraic INI ("Smoke Test")
We are replacing the application's complex UI system one piece at a time with a configuration-driven, "algebraic INI" approach. 

### Goals:
1. **Side-by-Side (SxS) Evolution:** Develop the new configuration-driven UI in `src/smoke_test/` while keeping the original system functional in parallel during the build out phase.
2. **Settings First:** Recreate the entire Settings module functionality using the INI config driving the `SmokeTest.Renderer.tsx` system.
3. **Pluggable & Portable:** The INI config approach acts as a simple abstract tree to decouple the UI structure from React DOM, allowing it to eventually be effortlessly parsed by other engines (.NET, Avalonia, C++, WebGPU).
4. **Extend to Other Tools:** Once Settings is fully working and swapped to be the primary view for settings, we will create a brand new Text Editor and File Manager configured through the algebraic INI system.

### Operating Principles:
- Data over structure. UI state should be defined in `config.ini` equivalent strings, or loaded through a simple key/value syntax.
- Build renderers that parse this INI and produce UI components (`ActionRow`, `Slider`, `Toggle`, etc.) iteratively.
- If it works, expand. If something is missing, add a new primitive type renderer and configure it via INI.
