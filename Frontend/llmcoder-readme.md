# Terminal UI Design System & Primitives Contract

**CRITICAL INSTRUCTION:** This document is the foundational UI and architectural contract for the entire frontend application. It must be consulted and strictly adhered to before any UI generation or component creation. 

## 1. File Naming Protocol & Extensibility
The project uses a strict, hierarchical dot-notation naming convention to cleanly separate concerns. Every component must be categorized by its Domain, Context, and Component name.
* **Format:** `Terminal.<Domain>.<Context>.tsx`
* **Examples:** `Terminal.Settings.Main.tsx`, `Terminal.UI.TabBar.tsx`, `Terminal.App.Console.tsx`
* **Why:** This ensures the codebase scales beautifully. Integrations, new apps, and UI elements drop into this structured layout, meaning the application can be largely JSON/schema-configurable while retaining perfect organization.

## 2. The Visual Rules & "Mica" Material Contract
The interface relies on simulating physical materials and architectural depth (Z-Axis) using CSS blurring, semi-transparent base tints, and vivid accents. 
**Do not use opaque, flat background colors for panels.**

* **Z-0 (Environment):** The vivid background environment.
* **Z-1 (Lens):** The primary floating panel (window). Uses `backdrop-blur` (Mica Blur), a variable opacity base tint (Base Panel Tint), and a subtle 1px inner light ring to define the physical "glass" edge.
* **Z-2 (Surface):** Inner cards used to group content. Distinct from the Lens by having a slightly lower opacity to sit visibly "on top," with tighter border radii.
* **Z-3 (Controls & Luminous Accents):** Interactive elements that pop above the glass layers using highly visible, bright luminous accent colors (like cyan/light blue) on active states.

## 3. The UI Primitives

### A. Material Layer Primitives
* **Lens (The Main Panel):** `backdrop-filter: blur(Xpx)`, `background-color: rgba(...)` (controlled by user settings), subtle inner white border at ~10% opacity.
* **Surface (The Inner Card):** Tighter padding, distinct subtle borders, layered over the Lens.

### B. Typography Primitives (Sans-serif, clean)
Opacity and scale drive hierarchy, not just size.
* **Header:** Breadcrumbs / Window Titles (e.g., "Settings > Personalization"). Bold, maximum brightness.
* **Title:** Inner card or group headers. Semibold, bright.
* **Label:** Interactive control titles. Medium weight, bright.
* **Caption:** Helper text under labels. Regular weight, 50-60% opacity. Must never visually compete with Labels.
* **MonoScale:** Values (e.g., "90%", "14px"). Monospaced / tabular-lining numbers, strictly right-aligned to create a crisp visual column edge.

### C. Interaction Primitives
* **The Glow Track (Sliders & Toggles):** The filled portion/active state must use the primary accent color with a subtle box-shadow/glow. Unfilled tracks remain at low opacity.
* **The Thumb:** Draggable circles on sliders must feel grounded. Use a dark center with an accent-colored border.
* **Action Row:** A full-width clickable surface that shifts background opacity on hover, typically containing a right chevron `>` to indicate navigation.
* **Selection Swatch:** Color or theme selectors. Active states receive an accent outline and a central indicator dot.

### D. Structural Primitives
* **Window Header:** The topmost structure acting as the "grip." Contains the hamburger menu, active tabs (with bottom accent glow), and window close buttons. 
* **Control Row:** A horizontal flexbox perfectly aligning the Label + Caption on the left, with the control (Slider, Switch, Swatch) on the right. Separated from sibling rows by a barely visible, gentle 1px border.

---
**CONTRACT:** Before building any new feature, panel, or application component, verify that it is composed entirely of these primitives. Maintain the exact padding hierarchy, translucent lens effects, typography scaling, and domain-driven file naming constraints listed above.

## 4. GPU-Accelerated JSON Theming Architecture

The system must be fully themable via simple JSON objects (e.g., standardizing an XP, Windows 8, or Glassmorphic theme) without altering the component DOM structure. 

### Implementation Rules:
* **JSON to CSS Variables:** The application state manages a JSON theme object. These values are mapped strictly to CSS Custom Properties (e.g., `--mica-bg-r`, `--mica-opacity`, `--accent-color`) injected into the `:root` or the window's container element.
* **Separation of Concerns:** React components only consume the CSS class names (e.g., `text-accent`, `bg-panel/50`). They do NOT compute inline styles or manipulate hardcoded colors.
* **Component Parsimony:** We maintain the minimal, Fluent/Win11 structural parsimony. A theme change alters the *aesthetic* (colors, opacities, blur radii, background images) via variables, but the layout and semantic markup remain untouched.
* **Hardware Acceleration (GPU):**
  * **Animations:** All continuous animations (like the Bliss clouds) and interactions (like panel sliding) must be hardware accelerated.
  * **Transforms vs Layout:** Manipulate `transform` and `opacity` **only** during animations. Never animate `width`, `height`, `margin`, or `top`/`left`.
  * **Compositor Promotion:** Use `translateZ(0)` or `translate3d(0,0,0)` carefully on animated layers to promote them to their own compositor texture, bypassing main-thread CPU repaints.
  * **Will-Change:** Use `will-change: transform` or `will-change: opacity` on elements that undergo frequent or complex transformations, allowing the browser to pre-allocate GPU memory.
  
By enforcing this JSON-to-variable pipeline combined with GPU-first CSS rendering, the UI remains self-discoverable, entirely configurable, and renders at maximum framerates regardless of the underlying theme's visual complexity.
