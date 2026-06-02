---@meta
--- keybindings/types.d.lua
--- Shared type definitions for the keybindings module.
--- This file is declaration-only and is not required at runtime.

---------------------------------------------------------------------------
-- Template engine
---------------------------------------------------------------------------

--- Interface for the template engine that resolves CSS/HTML placeholders.
--- @class OverlayTemplate
--- @field resolveCSS      fun(cfg: OverlayConfigStyles): string
--- @field buildHtml       fun(params: OverlayRenderParams): string
--- @field invalidateCache fun()

--- Parameters passed to OverlayTemplate.buildHtml() on each render.
--- @class OverlayRenderParams
--- @field resolvedCss  string  Pre-resolved CSS (from resolveCSS)
--- @field breadcrumb   string  Breadcrumb trail HTML
--- @field scrollTop    string  Scroll-up indicator HTML (or "")
--- @field tableRows    string  Binding table row HTML
--- @field scrollBottom string  Scroll-down indicator HTML (or "")
--- @field footer       string  Footer hint bar HTML

---------------------------------------------------------------------------
-- Overlay configuration
---------------------------------------------------------------------------

--- Default values for overlay layout and scroll math.
--- These fields must stay in sync with the CSS placeholders
--- %%FONT_SIZE%%, %%PADDING_V%%, and %%ENTRY_GAP%%.
--- @class OverlayConfigStyles
--- @field position    string   Screen anchor: "bottom_right"|"bottom_left"|"top_right"|"top_left"|"center"|"center_top"|"center_bottom"|"middle_left"|"middle_right"
--- @field margin      number   Pixel offset from the screen edge
--- @field maxHeight?  number|string  Maximum overlay height: number (device px), "Npx", or "N%" (default: "70%")
--- @field fontSize    number   Base font size — must match CSS %%FONT_SIZE%%
--- @field paddingV    number   Vertical panel padding — must match CSS %%PADDING_V%%
--- @field entryGap    number   Vertical padding per table row — must match CSS %%ENTRY_GAP%%
--- @field groupSuffix string   Text appended to group entry descriptions

--- Optional overrides for overlay styling passed via KeybindingsConfig.
--- All fields are optional; unset fields inherit from DEFAULTS.
--- @class OverlayConfigOverrides
--- @field position?    string   Screen anchor: "bottom_right"|"bottom_left"|"top_right"|"top_left"|"center"|"center_top"|"center_bottom"|"middle_left"|"middle_right"
--- @field margin?      number   Pixel offset from the screen edge
--- @field maxHeight?   number|string  Maximum overlay height: number (device px), "Npx", or "N%" (default: "70%")
--- @field fontSize?    number   Base font size — must match CSS %%FONT_SIZE%%
--- @field paddingV?    number   Vertical panel padding — must match CSS %%PADDING_V%%
--- @field entryGap?    number   Vertical padding per table row — must match CSS %%ENTRY_GAP%%
--- @field groupSuffix? string   Text appended to group entry descriptions

--- Full configuration passed to Overlay.new().
--- Inherits all OverlayConfigStyles fields (which are optional here, filled from DEFAULTS).
--- @class OverlayConfig : OverlayConfigStyles
--- @field template OverlayTemplate  Template engine (required, injected by caller)

---------------------------------------------------------------------------
-- Key dispatcher
---------------------------------------------------------------------------

--- Callbacks for keyboard event dispatching.
--- @class DispatcherCallbacks
--- @field onMatch      fun(childNode: BindingNode): boolean|nil
--- @field onEscape     fun()
--- @field onBackspace  fun()
--- @field onScrollDown fun()
--- @field onScrollUp   fun()
--- @field onUnmatched  fun(keyName: string, flags: table)
--- @field findChild    fun(keyName: string, flags: table): BindingNode|nil

--- @class Dispatcher
--- @field private callbacks  DispatcherCallbacks
--- @field private tap        hs.eventtap|nil

---------------------------------------------------------------------------
-- Binding tree
---------------------------------------------------------------------------

--- A single node in the binding tree. Leaf nodes hold an action;
--- interior nodes ("group") hold children keyed by normalized key string.
--- @class BindingNode
--- @field type           "group"|"action"|"sticky"
--- @field key            string         Lowercase key name (e.g. "r", "tab")
--- @field mods           string[]       Sorted modifier names (e.g. {"cmd","shift"})
--- @field desc           string         Human-readable description
--- @field icon           string|nil     Nerd Font icon glyph
--- @field action         fun()|number|nil  Callback or symbolic hotkey ID
--- @field parent         BindingNode|nil  Parent node (nil for root)
--- @field children       table<string, BindingNode>  Children keyed by normalized key
--- @field isGlobalHotkey boolean        True if root-level binding uses modifiers

---------------------------------------------------------------------------
-- Binding specification
---------------------------------------------------------------------------

--- Declarative specification for a single keybinding entry.
--- @class KeyBindingSpec
--- @field key            string              Key name (e.g. "r", "space", "tab")
--- @field mods?          string[]            Modifier keys (e.g. {"cmd","shift"})
--- @field desc?          string              Human-readable description
--- @field icon?          string              Nerd Font icon glyph
--- @field action?        fun()|number        Callback or symbolic hotkey ID (number = system shortcut)
--- @field group?         KeyBindingSpec[]    Sub-bindings (makes this a group node)
--- @field leader?        boolean             Place this entry under the leader group (default: false)
--- @field sticky?        boolean             Keep overlay open after action (default: false)

---------------------------------------------------------------------------
-- Keybindings engine
---------------------------------------------------------------------------

--- Leader key specification.
--- @class LeaderSpec
--- @field mods string[]  Modifier keys (e.g. {"alt","cmd"})
--- @field key  string    Key name (e.g. "space")

--- Configuration passed to Keybindings.setup().
--- @class KeybindingsConfig
--- @field leader                  LeaderSpec|nil           Leader key combo (nil = no leader)
--- @field overlay                 OverlayConfigOverrides|nil  Overlay styling overrides
--- @field timeout                 number|nil               Auto-dismiss seconds (nil = no timeout)
--- @field bindings                KeyBindingSpec[]|nil     The bindings table to register
--- @field disableSystemShortcuts  number[]|nil             Symbolic hotkey IDs to disable

---------------------------------------------------------------------------
-- Module state
---------------------------------------------------------------------------

--- @class KeybindingsState
--- @field root             BindingNode|nil
--- @field currentNode      BindingNode|nil
--- @field leaderNode       BindingNode|nil
--- @field overlayInstance   Overlay|nil
--- @field keyHandler        Dispatcher|nil
--- @field leaderHotkey      hs.hotkey|nil
--- @field globalTap         hs.eventtap|nil
--- @field globalBindings    table<string, BindingNode>
--- @field timeoutTimer      hs.timer|nil
--- @field config            KeybindingsConfig
--- @field navigationStack   BindingNode[]
--- @field errorSound        hs.sound|nil

---------------------------------------------------------------------------
-- Overlay instance
---------------------------------------------------------------------------

--- @class Overlay
--- @field private cfg               OverlayConfigStyles
--- @field private template          OverlayTemplate
--- @field private resolvedCss       string
--- @field private webview           hs.webview|nil
--- @field private ucc               hs.webview.usercontent|nil
--- @field private scrollOffset      number
--- @field private currentEntries    table[]
--- @field private currentBreadcrumb string|nil
