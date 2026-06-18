// icons.js — crisp inline SVG chrome glyphs. NOT font-dependent (the old PUA nerd-font glyph for the
// start button rendered as tofu / looked wrong). Stroke = currentColor, so each consumer colors it via
// the theme vars. Matches the ui-final icon set: Menu (bar at top) / Grip (bar at bottom).

export const ICON = {
  // hamburger — shown when the taskbar is docked TOP (the "menu" affordance, ui-final Menu).
  menu:
    '<svg class="ic" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor"' +
    ' stroke-width="2" stroke-linecap="round"><line x1="3" y1="6" x2="21" y2="6"/>' +
    '<line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/></svg>',
  // grip — shown when the taskbar is docked BOTTOM (the drag/handle affordance, ui-final Grip).
  grip:
    '<svg class="ic" width="22" height="22" viewBox="0 0 24 24" fill="currentColor" stroke="none">' +
    '<circle cx="5"  cy="5"  r="1.6"/><circle cx="12" cy="5"  r="1.6"/><circle cx="19" cy="5"  r="1.6"/>' +
    '<circle cx="5"  cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="19" cy="12" r="1.6"/>' +
    '<circle cx="5"  cy="19" r="1.6"/><circle cx="12" cy="19" r="1.6"/><circle cx="19" cy="19" r="1.6"/></svg>',
};

// The launch/start affordance icon for a given taskbar dock position (top = menu, bottom = grip).
export function launchIcon(position) { return position === 'bottom' ? ICON.grip : ICON.menu; }
