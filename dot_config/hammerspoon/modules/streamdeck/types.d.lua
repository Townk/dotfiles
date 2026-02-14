---@meta

--- @alias Image string | any # Path to image or a handle/surface object

--- A value that can be resolved: literal, function, or toggle table.
--- @alias Resolvable<T> T | fun(...): T | { on: T, off: T }

--- @alias AnchorHorizontal "start" | "center" | "end"
--- @alias AnchorVertical   "start" | "center" | "end"

--- @class Anchor
--- @field horizontal? AnchorHorizontal  # Horizontal alignment: "start" (left), "center", "end" (right).
--- @field vertical?   AnchorVertical    # Vertical placement: "start" (top), "center", "end" (bottom).

-- ============================================================
-- LAYERS
-- ============================================================

--- Canvas rendering context.
--- @class LayerContext
--- @field w number  Canvas width in pixels
--- @field h number  Canvas height in pixels

--- A composable layer function that adds canvas elements.
--- Encoder layers receive an optional 4th `value` argument.
--- @alias LayerFn fun(elements: table[], state: any, ctx: LayerContext, value?: any): table[]

-- ============================================================
-- BUTTONS
-- ============================================================

--- @class ButtonDef
--- @field state? any | fun(): any         # State provider. Defaults to `true`.
--- @field callback? fun(state: any)       # Press action.
--- @field callbackLong? fun(state: any)   # Long-press action.
--- @field poll? number                    # Per-input poll interval in seconds.
--- @field layers? LayerFn[]               # Custom composable layers (overrides standard).
--- @field icon? Resolvable<Image>         # Icon for standard layer.
--- @field iconOpts? { size: number?, color: any? }
--- @field label? Resolvable<string>       # Label for standard layer.
--- @field labelOpts? { position: Anchor?, padding: number?, size: number?, color: any? }
--- @field bgColor? Resolvable<table>      # Background color for standard layer.

--- @class Button
--- @field private _layers        function[]            Ordered list of layer functions
--- @field private _state         any                   State value or resolver
--- @field private _callback      (fun(state: any))|nil Press callback
--- @field private _callbackLong  (fun(state: any))|nil Long-press callback
--- @field poll?    (fun(): any)|nil                    Optional poll function
--- @field state    fun(self: Button): any
--- @field render   fun(self: Button, state: any, ctx: LayerContext): table[]
--- @field onPress  fun(self: Button, state: any)
--- @field onLongPress fun(self: Button, state: any)

--- @class ButtonToggler : Button

-- ============================================================
-- ENCODERS
-- ============================================================

--- @class EncoderCallbacks
--- @field state?             any | fun(): any
--- @field value?             any | fun(): any
--- @field poll?              number
--- @field callbackInc?       fun(state: any, value: any, secondary: boolean): any
--- @field callbackDec?       fun(state: any, value: any, secondary: boolean): any
--- @field callbackPress?     fun(state: any, value: any)
--- @field callbackTouch?     fun(state: any, value: any)
--- @field callbackTouchLong? fun(state: any, value: any)

--- @class EncoderDef : EncoderCallbacks
--- @field layers? LayerFn[]

--- Layout configuration for an encoder display.
--- All fields are optional; omitted fields fall back to the defaults
--- defined in layers.ENC_DEFAULTS (padding=5, inset=5, etc.).
--- @class EncoderLayoutOpts
--- @field padding?       number  Canvas-edge → available-area inset on all sides (default 5)
--- @field inset?         number  Gap between stacked elements within the area (default 5)
--- @field titleFontSize? number  Title text font size (default 14)
--- @field titleAnchor?   Anchor  Title alignment within its row (default { horizontal="start", vertical="center" })
--- @field badgeSize?     number  Badge icon square size in pixels (default 16)
--- @field iconSize?      number  Split-layout icon size as fraction 0.0–1.0 of its column area's shorter dimension (default 0.85)
--- @field iconAnchor?    Anchor  Icon alignment within its column area (default { horizontal="center", vertical="center" })
--- @field barHeight?     number  Progress bar height in pixels (default 10)
--- @field valueFontSize? number  Progress value text font size (default 28)

--- Pre-computed layout produced by layers.computeEncoderLayout().
--- Passed into every encoder layer factory so all elements share
--- a consistent coordinate system derived from the same options.
--- @class EncoderLayout
--- @field titleFontSize  number
--- @field titleAnchor    Anchor
--- @field badgeSize      number
--- @field valueFontSize  number
--- @field iconAnchor     Anchor
--- @field availableArea  { x: number, y: number, w: number, h: number }
--- @field titleFrame     { x: number, y: number, w: number, h: number }
--- @field badgeFrame     { x: number, y: number, w: number, h: number }
--- @field iconFrame      { x: number, y: number, w: number, h: number }
--- @field iconFullFrame  { x: number, y: number, w: number, h: number }
--- @field barFrame       { x: number, y: number, w: number, h: number }
--- @field valueFrame     { x: number, y: number, w: number, h: number }
--- @field descFrame      { x: number, y: number, w: number, h: number }

--- @class ValueBarDef : EncoderCallbacks
--- @field title         any
--- @field icon          any
--- @field iconOpts?     { tint?: any, gradient?: any }
--- @field status        any
--- @field barColor?     any
--- @field layoutOpts?   EncoderLayoutOpts
--- @field displayValue? fun(state: any, value: any): any
--- @field barValue?     fun(state: any, value: any): any

--- @class IconDef : EncoderCallbacks
--- @field title       any
--- @field icon        any
--- @field iconOpts?   { tint?: any, gradient?: any }
--- @field layoutOpts? EncoderLayoutOpts

--- @class TextDef : EncoderCallbacks
--- @field title       any
--- @field icon        any
--- @field iconOpts?   { tint?: any, gradient?: any }
--- @field description any
--- @field descColor?  any
--- @field layoutOpts? EncoderLayoutOpts

--- @class EncoderStackDef
--- @field encoders    Encoder[]
--- @field poll?       number
--- @field layoutOpts? EncoderLayoutOpts
--- @field badgeOpts?  { tint?: any, gradient?: any }

--- @class Encoder
--- @field _layers                     LayerFn[]|nil
--- @field _title                      any
--- @field private _state              any
--- @field private _value              any
--- @field private _callbackInc        (fun(state: any, value: any, secondary: boolean): any)|nil
--- @field private _callbackDec        (fun(state: any, value: any, secondary: boolean): any)|nil
--- @field private _callbackPress      (fun(state: any, value: any))|nil
--- @field private _callbackTouch      (fun(state: any, value: any))|nil
--- @field private _callbackTouchLong  (fun(state: any, value: any))|nil
--- @field poll?       number|nil
--- @field state       fun(self: Encoder): any
--- @field value       fun(self: Encoder): any
--- @field render      fun(self: Encoder, state: any, value: any, ctx: LayerContext, elements?: table[]): table[]
--- @field onInc       fun(self: Encoder, state: any, value: any, secondary: boolean): any
--- @field onDec       fun(self: Encoder, state: any, value: any, secondary: boolean): any
--- @field onPress     fun(self: Encoder, state: any, value: any)
--- @field onTouch     fun(self: Encoder, state: any, value: any)
--- @field onTouchLong fun(self: Encoder, state: any, value: any)

--- @class EncoderStack
--- @field private _encoders   Encoder[]
--- @field private _active     number
--- @field private _selecting  boolean
--- @field private _pickerLayer LayerFn
--- @field _layers              LayerFn[]|nil
--- @field poll?               number|nil
--- @field state       fun(self: EncoderStack): any
--- @field value       fun(self: EncoderStack): any
--- @field render      fun(self: EncoderStack, state: any, value: any, ctx: LayerContext): table[]
--- @field onInc       fun(self: EncoderStack, state: any, value: any, secondary: boolean): any
--- @field onDec       fun(self: EncoderStack, state: any, value: any, secondary: boolean): any
--- @field onPress     fun(self: EncoderStack, state: any, value: any)
--- @field onTouch     fun(self: EncoderStack, state: any, value: any)
--- @field onTouchLong fun(self: EncoderStack, state: any, value: any)


-- ============================================================
-- PRESETS
-- ============================================================

--- @class StreamDeckPresets
--- @field buttons table<string, ButtonDef>
--- @field encoders table<string, EncoderDef>

--- @class AudioDeviceRepr
--- @field icon string
--- @field name string

-- ============================================================
-- CONFIG STRUCTURE
-- ============================================================

--- @class ButtonsBackground
--- @field image Image
--- @field horizontalInset number
--- @field verticalInset number

--- @class Inputs
--- @field buttons (Button|nil)[]  # Array-style table (1-8 for SD+, 1-15 for MK.2)
--- @field encoders? (Encoder|nil)[] # Array-style table (1-4 for SD+)

--- @class Page
--- @field id number | string
--- @field name string
--- @field encodersBackground? Image
--- @field buttonsBackground? Image | ButtonsBackground
--- @field inputs Inputs
--- @field onSwipeLeft? string | number
--- @field onSwipeRight? string | number

--- @class Profile
--- @field id number | string
--- @field name string
--- @field fallback? Inputs
--- @field pages Page[]

--- @class StreamDeckConfig
--- @field profiles Profile[]
--- @field defaultProfile number | string
--- @field brightness? number | fun(): number
