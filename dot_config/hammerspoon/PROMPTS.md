# Claude Prompts

<!--toc:start-->
- [Claude Prompts](#claude-prompts)
  - [Stream Deck+ Declarative Configuration Schema](#stream-deck-declarative-configuration-schema)
    - [1. Core Types](#1-core-types)
      - [`Image`](#image)
      - [`EncoderLayout`](#encoderlayout)
    - [2. Input Components](#2-input-components)
      - [`Button`](#button)
      - [`Encoder`](#encoder)
    - [3. Layout & Organization](#3-layout-organization)
      - [`ButtonsBackground`](#buttonsbackground)
    - [`Inputs`](#inputs)
      - [`Page`](#page)
    - [4. Device Level](#4-device-level)
      - [`Profile`](#profile)
      - [`StreamDeck`](#streamdeck)
      - [Usage Example: Volume Control](#usage-example-volume-control)
    - [Lua type annotations for the schema](#lua-type-annotations-for-the-schema)
    - [Encoder display layouts](#encoder-display-layouts)
<!--toc:end-->

## Stream Deck+ Declarative Configuration Schema

This document defines a functional, state-driven schema for the Elgato Stream
Deck+ and similar devices. It uses a **State-Value-Callback** pattern to ensure
the hardware UI remains a "view" of your system's underlying state.

---

### 1. Core Types

#### `Image`

A union type representing a visual asset.

- **Type:** `string` (file path) | `userdata` (image handle or surface object).

#### `EncoderLayout`

Determines the visual template for the LCD strip segment above a physical dial.

- `icon_status`: Large icon left-aligned and vertically centralized with status
  text on its right.
- `value_bar`: A horizontal progress bar based on `status.min/max`. It has a
  large icon left-aligned and vertically centralized, with a label text on the
  top right side, and a progress bar on the bottom right side with a text
  representing the percent value of it.
- `full_canvas`: The image or icon fills the entire segment (~200x100px).
- `text_only`: Uses the `label` and `status` strings and no icons.

---

### 2. Input Components

#### `Button`

Represents a tactile physical key (e.g., the 8-button grid on the SD+).

|Property|Type|Description|
|---|---|---|
|**`state`**|`any \| function`|The "source of truth." Defaults to `true`.|
|**`icon`**|`Image \| function(s)`|The icon to display. Reactive to `state`.|
|**`label`**|`string \| function(s)`|Text overlay on the button. Reactive to `state`.|
|**`callback`**|`function(s): bool`|Triggered on press. Return `true` to force a UI redraw.|
|**`callbackLong`**|`function(s): bool`|_Optional._ Triggered when held (> 500ms).|

---

#### `Encoder`

Represents the 360° rotary dials and the associated capacitive LCD strip segment.

|Property|Type|Description|
|---|---|---|
|**`state`**|`any \| function`|General state (e.g., "Is Muted").|
|**`value`**|`any \| function`|Numeric or discrete value (e.g., Volume `75`).|
|**`icon`**|`function(s, v)`|Image shown on the LCD segment.|
|**`label`**|`function(s, v)`|Primary text displayed on the LCD segment.|
|**`layout`**|`EncoderLayout`|_Optional._ Visual template for the LCD segment.|
|**`status`**|`string \| table \| function`|Text or `{min, max}` range for progress bars.|
|**`callbackInc`**|`function(s, v, sec)`|Clockwise turn. Returns the **new value**.|
|**`callbackDec`**|`function(s, v, sec)`|Counter-clockwise turn. Returns the **new value**.|
|**`callbackPress`**|`function(s, v)`|Triggered when the physical dial is clicked.|
|**`callbackTouch`**|`function(s, v)`|Triggered when the LCD segment is tapped.|
|**`callbackTouchLong`**|`function(s, v)`|Triggered when the LCD segment is held (> 500ms).|

> **Note on `secondary`:** In `callbackInc/Dec`, the `secondary` boolean is
> `true` if the dial is being rotated while physically pressed down.

---

### 3. Layout & Organization

#### `ButtonsBackground`

Defines how a single image is applied across the tactile button grid. This
image will be used as the first layer of the composable image for the button
background.

- **`image`**: The source image asset.
- **`horizontalInset` / `verticalInset`**: Margin in pixels for the background slice.

### `Inputs`

The container for active controls on a single page.

- **`buttons`**: Array-style table (index 1-8 for SD+).
- **`encoders`**: Array-style table (index 1-4 for SD+).

---

#### `Page`

A specific set of controls and visuals visible at one time.

|Property|Type|Description|
|---|---|---|
|**`id`**|`number \| string`|Unique identifier for navigation.|
|**`name`**|`string`|Display name for logs/menus.|
|**`encodersBackground`**|`Image`|Wide image (800×100) for the LCD strip.|
|**`buttonsBackground`**|`Image \| ButtonsBackground`|Background for the button area.|
|**`inputs`**|`Inputs`|The button and encoder definitions.|
|**`onSwipeLeft`**|`id`|Page ID to transition to on left swipe.|
|**`onSwipeRight`**|`id`|Page ID to transition to on right swipe.|

---

### 4. Device Level

#### `Profile`

A collection of pages, usually grouped by application or context.

- **`id`**: Unique identifier.
- **`fallback`**: An `Inputs` table used if a `Page` has empty slots.
- **`pages`**: A table containing `Page` objects.

#### `StreamDeck`

The top-level configuration for the physical hardware.

- **`profiles`**: Table of available profiles.
- **`defaultProfile`**: The ID of the profile to load on startup.
- **`brightness`**: `number` (0-100) or a function for dynamic dimming.

---

#### Usage Example: Volume Control

Lua

```
local volume_knob = {
    value = function() return system.get_volume() end,
    status = { min = 0, max = 100 },
    layout = "value_bar",
    callbackInc = function(_, v, sec) 
        local step = sec and 10 or 2 -- Faster if pressed
        return math.min(v + step, 100) 
    end,
    callbackPress = function() 
        system.toggle_mute() 
        return true -- Refresh UI
    end
}
```

### Lua type annotations for the schema

```lua
---@meta

---@alias Image string | any # Path to image or a handle/surface object

---@class Button
---@field state any | (fun(): any) # Current state or state provider. Defaults to `true`.
---@field icon Image | (fun(curState: any): Image)
---@field label string | (fun(curState: any): string)
---@field callback fun(curState: any): boolean # Returns true if display needs immediate refresh.
---@field callbackLongPress? fun(curState: any): boolean # Optional long-press action.

---@alias EncoderLayout "icon_status" | "value_bar" | "full_canvas" | "text_only"

---@class Encoder
---@field state any | (fun(): any)
---@field value any | (fun(): any)
---@field icon Image | (fun(curState: any, curValue: any): Image)
---@field label string | (fun(curState: any, curValue: any): string)
---@field layout? EncoderLayout # UI template for the LCD segment.
---@field status? string | {min: number, max: number} | (fun(curState: any, curValue: any): string)
---@field callbackInc fun(curState: any, curValue: any, secondary: boolean): any # Returns new value.
---@field callbackDec fun(curState: any, curValue: any, secondary: boolean): any # Returns new value.
---@field callbackPress? fun(curState: any, curValue: any): boolean # Physical knob click.
---@field callbackTouch? fun(curState: any, curValue: any): boolean # LCD strip tap above knob.
---@field callbackTouchLong? fun(curState: any, curValue: any): boolean # LCD strip long press.

---@class ButtonsBackground
---@field image Image
---@field horizontalInset number
---@field verticalInset number

---@class Inputs
---@field buttons (Button|nil)[] # Array-style table (1-8 for SD+, 1-15 for MK.2)
---@field encoders? (Encoder|nil)[] # Array-style table (1-4 for SD+)

---@class Page
---@field id number | string
---@field name string
---@field encodersBackground? Image # For the LCD Strip background
---@field buttonsBackground? Image | ButtonsBackground
---@field inputs Inputs
---@field onSwipeLeft? string | number # ID of page to transition to
---@field onSwipeRight? string | number # ID of page to transition to

---@class Profile
---@field id number | string
---@field name string
---@field fallback? Inputs # Global inputs if page-specific ones are nil
---@field pages Page[]

---@class StreamDeck
---@field profiles Profile[]
---@field defaultProfile number | string
---@field brightness? number | (fun(): number) # 0-100
```

### Encoder display layouts

```
╭─╮ ┬
│ │├🮯┤
╰─╯ ┴
╭─────────────────────────────╮
│ Title                 Badge │
├─────────┬───────────────────┤
│         │                   │
│  ICON   │    Progress Label │
│         │      Progress Bar │
╰─────────┴───────────────────╯

╭─────────┬─────────┬─────────╮
│         │         │         │
├─────────🮯─────────🮯─────────┤
│         │         │         │
├─────────🮯─────────🮯─────────┤
│         │         │         │
╰─────────┴─────────┴─────────╯

```
