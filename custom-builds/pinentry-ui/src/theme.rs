//! Colours, taken from the generated palette so a theme switch re-colours this
//! dialog with everything else.
//!
//! The palette is read from the shell projection
//! (`~/.config/theme/chezmoi-system.zsh`) rather than the JSON twin, because its
//! `C_ROLE_NAME="#rrggbb"` lines need no parser — and a parser would be a
//! dependency inside a program that handles passphrases.
//!
//! Reading a file at a fixed path is not laziness about the environment: this
//! process is spawned by gpg-agent, whose environment is minimal and carries
//! none of the `C_*` variables an interactive shell would have exported.

use std::collections::HashMap;
use std::fmt::Write as _;

/// One role per thing the dialog paints. The set is the one the ai-playbook
/// `ask` widgets use (`pkg/dialog/theme.go`), so the two dialogs recolour
/// together: its Border/Accent/Rule/Text/Muted/Key/FieldBorder/Mantle are the
/// same hexes as our BORDER_FOCUS/TITLE/SEPARATOR/FG/OVERLAY/KEY/BORDER/
/// DIALOG_BG.
pub struct Theme {
    pub title: String,
    pub text: String,
    pub rule: String,
    pub border: String,
    pub field_border: String,
    /// The key's identifying marks — green, and always present.
    pub fact: String,
    /// The requester line when it is somebody else's pane — yellow, and drawn
    /// only then, so the colour keeps its meaning.
    pub alert: String,
    pub input: String,
    pub key: String,
    pub hint: String,
    pub danger: String,
    /// A background, not a foreground: every row of the dialog paints on it so
    /// the box reads as a card rather than a wireframe over the pane.
    pub bg: String,
}

pub const RESET: &str = "\x1b[0m";
pub const BOLD: &str = "\x1b[1m";

impl Theme {
    /// Never fails. A host with no generated palette — or a stripped-down one
    /// where the file has not been written yet — gets the basic ANSI set, which
    /// is legible everywhere rather than pretty anywhere.
    pub fn load() -> Self {
        let roles = read_roles().unwrap_or_default();
        let pick = |role: &str, fallback: &str| -> String {
            roles
                .get(role)
                .and_then(|hex| sgr(hex, FG))
                .unwrap_or_else(|| fallback.to_string())
        };
        Self {
            title: pick("C_ROLE_UI_TITLE", "\x1b[35m"),
            text: pick("C_ROLE_UI_FG", "\x1b[0m"),
            rule: pick("C_ROLE_UI_SEPARATOR", "\x1b[90m"),
            border: pick("C_ROLE_UI_BORDER_FOCUS", "\x1b[34m"),
            field_border: pick("C_ROLE_UI_BORDER", "\x1b[90m"),
            // Green for the key's identifying marks. They are neutral detail,
            // and no role means "identifying detail", so this is the least
            // wrong of the three names sharing the hex: not STATE_SUCCESS,
            // which would claim something succeeded, and not ACTION_RUN. The
            // key block is the thing you confirm before typing.
            fact: pick("C_ROLE_ACTION_CONFIRM", "\x1b[32m"),
            // Yellow, and reserved: it appears only when the request came from
            // a pane you are not attached to. Sharing it with anything the
            // dialog always draws would spend the one colour that has to still
            // mean something on the day it matters. The role that means "look
            // here" rather than the same-hex STATE_WARNING, which would say
            // something is wrong and collide with the danger variant.
            alert: pick("C_ROLE_ACTION_ATTENTION", "\x1b[33m"),
            input: pick("C_ROLE_UI_INPUT_FG", "\x1b[0m"),
            key: pick("C_ROLE_UI_KEY", "\x1b[97m"),
            hint: pick("C_ROLE_UI_OVERLAY", "\x1b[2m"),
            danger: pick("C_ROLE_STATE_ERROR", "\x1b[31m"),
            // No fallback fill: on a host with no palette the card would be a
            // guess at the terminal's own background, and guessing wrong paints
            // a black rectangle onto a light theme.
            bg: roles
                .get("C_ROLE_UI_DIALOG_BG")
                .and_then(|hex| sgr(hex, BG))
                .unwrap_or_default(),
        }
    }
}

fn read_roles() -> Option<HashMap<String, String>> {
    let home = std::env::var_os("HOME")?;
    let mut path = std::path::PathBuf::from(home);
    path.push(".config/theme/chezmoi-system.zsh");
    let text = std::fs::read_to_string(path).ok()?;

    let mut roles = HashMap::new();
    for line in text.lines() {
        let Some(rest) = line.strip_prefix("C_ROLE_") else {
            continue;
        };
        let Some((name, value)) = rest.split_once('=') else {
            continue;
        };
        let value = value.trim().trim_matches('"');
        if value.starts_with('#') {
            roles.insert(format!("C_ROLE_{name}"), value.to_string());
        }
    }
    Some(roles)
}

const FG: u8 = 38;
const BG: u8 = 48;

/// `#rrggbb` to a truecolor SGR on `layer`. Returns None for anything that is
/// not exactly that, so a malformed palette degrades to the fallback instead of
/// emitting a broken escape into the middle of the dialog.
fn sgr(hex: &str, layer: u8) -> Option<String> {
    let hex = hex.strip_prefix('#')?;
    if hex.len() != 6 {
        return None;
    }
    let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
    let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
    let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
    let mut out = String::new();
    let _ = write!(out, "\x1b[{layer};2;{r};{g};{b}m");
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_hex_to_truecolor() {
        assert_eq!(sgr("#89b4fa", FG).unwrap(), "\x1b[38;2;137;180;250m");
        assert_eq!(sgr("#181825", BG).unwrap(), "\x1b[48;2;24;24;37m");
    }

    #[test]
    fn rejects_malformed_hex_rather_than_emitting_garbage() {
        assert!(sgr("89b4fa", FG).is_none());
        assert!(sgr("#89b4f", FG).is_none());
        assert!(sgr("#zzzzzz", FG).is_none());
    }
}
