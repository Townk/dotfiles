# Keyboard-key symbols

A curated reference of Unicode symbols for keyboard keys — common modifiers
through to the uncommon ones covered by firmware like **QMK** and **ZMK**
(consumer/system/media keycodes). Every Mono and Color glyph here is confirmed
covered by this machine's terminal font stack.

## How to read these tables

- **Mono** — the monochrome / text-presentation glyph.
- **Color** — the emoji-presentation glyph.
- **Code-point column** — in the `Color`/`Mono` code-point cells, `FE0E` =
  variation selector 15 (force text/mono) and `FE0F` = VS16 (force emoji/color).
  These appear only when the *same* character flips presentation.
- `—` means no glyph of that kind is covered by the stack.

### Standards

| Tag | Meaning |
| --- | --- |
| **ISO 9995-7** | ISO/IEC 9995-7 *"Symbols used to represent functions"* — the official keyboard-function symbol (number, where confirmed from the Unicode WG2 mapping). |
| **IEC 60417 / IEEE 1621** | Power/sleep symbols (IEC 60417 = ISO 7000:2012; IEEE 1621 added sleep). |
| **Unicode** | A generic Unicode symbol/arrow, not a keyboard-specific standard. |
| **APL** | An APL functional symbol borrowed for keyboard use. |
| **vendor / convention** | No formal standard — Apple/Microsoft usage or common convention. |

> **Terminal note:** the WezTerm config here intentionally routes text-default
> emoji to color, so the Color forms render even without VS16. Append `U+FE0E`
> to force Mono in that terminal.
>
> **ISO combining forms:** a few ISO 9995-7 symbols (e.g. Scroll Lock, Help)
> are formally a base character + `U+20E2` COMBINING ENCLOSING SCREEN, which the
> stack does not cover — so the single-codepoint glyphs below are used instead.

## Modifiers

| Key | Mono | Color | Mono CP | Color CP | Unicode name (mono) | Standard |
| --- | :---: | :---: | --- | --- | --- | --- |
| Command / ⌘ | ⌘ | — | `U+2318` | — | PLACE OF INTEREST SIGN | vendor (Apple) |
| Control | ⌃ | — | `U+2303` | — | UP ARROWHEAD | vendor (Apple) |
| Control (ISO) | ⎈ | — | `U+2388` | — | HELM SYMBOL | ISO 9995-7 #26 |
| Option / Alt | ⌥ | — | `U+2325` | — | OPTION KEY | vendor (Apple) |
| Alt (ISO) | ⎇ | — | `U+2387` | — | ALTERNATIVE KEY SYMBOL | ISO 9995-7 #25 |
| Shift | ⇧ | — | `U+21E7` | — | UPWARDS WHITE ARROW | ISO 9995-7 #1 |
| Meta | ◆ | — | `U+25C6` | — | BLACK DIAMOND | convention |
| Windows / Super | ⊞ | — | `U+229E` | — | SQUARED PLUS | vendor (no std) |
| Windows (alt) | ❖ | — | `U+2756` | — | BLACK DIAMOND MINUS WHITE X | vendor (no std) |
| Menu / App | ☰ | — | `U+2630` | — | TRIGRAM FOR HEAVEN | convention |
| Menu (alt) | ⧉ | — | `U+29C9` | — | TWO JOINED SQUARES | convention |
| Fn | 🌐︎ | 🌐 | `U+1F310 FE0E` | `U+1F310` | GLOBE WITH MERIDIANS | vendor (Apple) |

## Locks

| Key | Mono | Color | Mono CP | Color CP | Unicode name (mono) | Standard |
| --- | :---: | :---: | --- | --- | --- | --- |
| Caps Lock | ⇪ | — | `U+21EA` | — | UPWARDS WHITE ARROW FROM BAR | ISO 9995-7 |
| Num Lock | ⇭ | — | `U+21ED` | — | UPWARDS WHITE ARROW ON PEDESTAL WITH VERTICAL BAR | ISO 9995-7 #4 |
| Scroll Lock | ⇳ | — | `U+21F3` | — | UP DOWN WHITE ARROW | ISO 9995-7 |
| Fn-Lock | ⇫ | ⚙️ | `U+21EB` | `U+2699 FE0F` | UPWARDS WHITE ARROW ON PEDESTAL | ISO 9995-7 |

## Editing

| Key | Mono | Color | Mono CP | Color CP | Unicode name (mono) | Standard |
| --- | :---: | :---: | --- | --- | --- | --- |
| Escape | ⎋ | — | `U+238B` | — | BROKEN CIRCLE WITH NORTHWEST ARROW | ISO 9995-7 |
| Backspace | ⌫ | — | `U+232B` | — | ERASE TO THE LEFT | ISO 9995-7 |
| Forward Delete | ⌦ | — | `U+2326` | — | ERASE TO THE RIGHT | ISO 9995-7 |
| Delete (alt) | ␡ | — | `U+2421` | — | SYMBOL FOR DELETE | Unicode |
| Insert | ⎀ | — | `U+2380` | — | INSERTION SYMBOL | ISO 9995-7 |
| Clear | ⌧ | — | `U+2327` | — | X IN A RECTANGLE BOX | ISO 9995-7 |
| Clear Screen (alt) | ⎚ | — | `U+239A` | — | CLEAR SCREEN SYMBOL | ISO 9995-7 |
| Undo | ⎌ | — | `U+238C` | — | UNDO SYMBOL | ISO 9995-7 |
| Compose | ⎄ | — | `U+2304` | — | DOWN ARROWHEAD | convention |
| Help | ⍰ | ❓ | `U+2370` | `U+2753` | APL FUNCTIONAL SYMBOL QUAD QUESTION | APL |

## Whitespace / submit

| Key | Mono | Color | Mono CP | Color CP | Unicode name (mono) | Standard |
| --- | :---: | :---: | --- | --- | --- | --- |
| Return | ⏎ | ↩️ | `U+23CE` | `U+21A9 FE0F` | RETURN SYMBOL | ISO 9995-7 |
| Enter (numpad) | ⌤ | — | `U+2324` | — | UP ARROWHEAD BETWEEN TWO HORIZONTAL BARS | ISO 9995-7 |
| Enter (alt) | ⎆ | — | `U+2386` | — | ENTER SYMBOL | ISO 9995-7 #24 |
| Tab | ⇥ | — | `U+21E5` | — | RIGHTWARDS ARROW TO BAR | ISO 9995-7 |
| Tab (back) | ⇤ | — | `U+21E4` | — | LEFTWARDS ARROW TO BAR | ISO 9995-7 |
| Tab (back, alt) | ↹ | — | `U+21B9` | — | LEFTWARDS ARROW TO BAR OVER RIGHTWARDS ARROW TO BAR | Unicode |
| Spacebar | ␣ | — | `U+2423` | — | OPEN BOX | ISO 9995-7 |
| Spacebar (alt) | ⎵ | — | `U+23B5` | — | BOTTOM SQUARE BRACKET | Unicode |

## System / navigation

| Key | Mono | Color | Mono CP | Color CP | Unicode name (mono) | Standard |
| --- | :---: | :---: | --- | --- | --- | --- |
| Print Screen | ⎙ | — | `U+2399` | — | PRINT SCREEN SYMBOL | ISO 9995-7 #22 |
| Pause | ⎉ | ⏸️ | `U+2389` | `U+23F8 FE0F` | CIRCLED HORIZONTAL BAR WITH NOTCH | ISO 9995-7 #27 |
| Break | ⎊ | — | `U+238A` | — | CIRCLED TRIANGLE DOWN | ISO 9995-7 #28 |
| Home | ⇱ | ↖️ | `U+21F1` | `U+2196 FE0F` | NORTH WEST ARROW TO CORNER | ISO 9995-7 |
| End | ⇲ | ↘️ | `U+21F2` | `U+2198 FE0F` | SOUTH EAST ARROW TO CORNER | ISO 9995-7 |
| Page Up | ⇞ | — | `U+21DE` | — | UPWARDS ARROW WITH DOUBLE STROKE | Unicode |
| Page Down | ⇟ | — | `U+21DF` | — | DOWNWARDS ARROW WITH DOUBLE STROKE | Unicode |

## Media (QMK `KC_MEDIA_*` / ZMK `&kp C_*`)

| Key | Mono | Color | Mono CP | Color CP | Unicode name (mono) | Standard |
| --- | :---: | :---: | --- | --- | --- | --- |
| Play | ⏵ | ▶️ | `U+23F5` | `U+25B6 FE0F` | BLACK MEDIUM RIGHT-POINTING TRIANGLE | Unicode |
| Play / Pause | ⏯︎ | ⏯ | `U+23EF FE0E` | `U+23EF` | BLACK RIGHT-POINTING TRIANGLE WITH DOUBLE VERTICAL BAR | Unicode |
| Pause | ⏸︎ | ⏸ | `U+23F8 FE0E` | `U+23F8` | DOUBLE VERTICAL BAR | Unicode |
| Stop | ⏹︎ | ⏹ | `U+23F9 FE0E` | `U+23F9` | BLACK SQUARE FOR STOP | Unicode |
| Record | ⏺︎ | ⏺ | `U+23FA FE0E` | `U+23FA` | BLACK CIRCLE FOR RECORD | Unicode |
| Next Track | ⏭︎ | ⏭ | `U+23ED FE0E` | `U+23ED` | BLACK RIGHT-POINTING DOUBLE TRIANGLE WITH VERTICAL BAR | Unicode |
| Prev Track | ⏮︎ | ⏮ | `U+23EE FE0E` | `U+23EE` | BLACK LEFT-POINTING DOUBLE TRIANGLE WITH VERTICAL BAR | Unicode |
| Fast-Forward | ⏩︎ | ⏩ | `U+23E9 FE0E` | `U+23E9` | BLACK RIGHT-POINTING DOUBLE TRIANGLE | Unicode |
| Rewind | ⏪︎ | ⏪ | `U+23EA FE0E` | `U+23EA` | BLACK LEFT-POINTING DOUBLE TRIANGLE | Unicode |
| Eject | ⏏︎ | ⏏️ | `U+23CF` | `U+23CF FE0F` | EJECT SYMBOL | ISO 9995-7 |

## Volume / brightness

Color-only on this stack. For monochrome volume/brightness, a symbol font like
Noto Sans Symbols 2 would need to be ordered ahead of Apple Color Emoji.

| Key | Mono | Color | Mono CP | Color CP | Unicode name | Standard |
| --- | :---: | :---: | --- | --- | --- | --- |
| Mute | — | 🔇 | — | `U+1F507` | SPEAKER WITH CANCELLATION STROKE | Unicode |
| Volume Down | — | 🔉 | — | `U+1F509` | SPEAKER WITH ONE SOUND WAVE | Unicode |
| Volume Up | — | 🔊 | — | `U+1F50A` | SPEAKER WITH THREE SOUND WAVES | Unicode |
| Speaker | — | 🔈 | — | `U+1F508` | SPEAKER | Unicode |
| Brightness Down | — | 🔅 | — | `U+1F505` | LOW BRIGHTNESS SYMBOL | Unicode |
| Brightness Up | — | 🔆 | — | `U+1F506` | HIGH BRIGHTNESS SYMBOL | Unicode |
| Brightness (sun) | ☀︎ | ☀️ | `U+2600` | `U+2600 FE0F` | BLACK SUN WITH RAYS | Unicode |

## Power / sleep (IEC 60417 / IEEE 1621)

| Key | Mono | Color | Mono CP | Color CP | Unicode name (mono) | Standard |
| --- | :---: | :---: | --- | --- | --- | --- |
| Power | ⏻ | — | `U+23FB` | — | POWER SYMBOL | IEC 60417-5009 / IEEE 1621 |
| Power On-Off | ⏼ | — | `U+23FC` | — | POWER ON-OFF SYMBOL | IEC 60417-5010 |
| Power On | ⏽ | — | `U+23FD` | — | POWER ON SYMBOL | IEC 60417-5007 |
| Power Off | ⭘ | — | `U+2B58` | — | HEAVY CIRCLE | IEC 60417-5008 |
| Sleep (power) | ⏾ | — | `U+23FE` | — | POWER SLEEP SYMBOL | IEEE 1621 |
| Sleep (moon) | ☾ | 🌙 | `U+263E` | `U+1F319` | LAST QUARTER MOON | Unicode |

## Arrow / cursor keys

| Key | Mono | Color | Mono CP | Color CP | Unicode name (mono) | Standard |
| --- | :---: | :---: | --- | --- | --- | --- |
| Up | ↑ | ⬆️ | `U+2191` | `U+2B06` | UPWARDS ARROW | Unicode |
| Down | ↓ | ⬇️ | `U+2193` | `U+2B07` | DOWNWARDS ARROW | Unicode |
| Left | ← | ⬅️ | `U+2190` | `U+2B05` | LEFTWARDS ARROW | Unicode |
| Right | → | ➡️ | `U+2192` | `U+27A1` | RIGHTWARDS ARROW | Unicode |
| Up (triangle) | ▲ | 🔼 | `U+25B2` | `U+1F53C` | BLACK UP-POINTING TRIANGLE | Unicode |
| Down (triangle) | ▼ | 🔽 | `U+25BC` | `U+1F53D` | BLACK DOWN-POINTING TRIANGLE | Unicode |
| Left (triangle) | ◀ | ◀️ | `U+25C0` | `U+25C0 FE0F` | BLACK LEFT-POINTING TRIANGLE | Unicode |
| Right (triangle) | ▶ | ▶️ | `U+25B6` | `U+25B6 FE0F` | BLACK RIGHT-POINTING TRIANGLE | Unicode |
