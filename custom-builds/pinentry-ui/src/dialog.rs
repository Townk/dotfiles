//! The dialog: layout, drawing, and the key loop that fills the buffer.
//!
//! Nothing here formats the passphrase. The masked field is drawn from a
//! character *count*, never from the bytes, so there is no path from the buffer
//! to the screen even by accident.
//!
//! The layout is the ai-playbook `ask` widget's, reproduced from
//! `pkg/dialog/frame.go` and `pkg/dialog/field_text.go` so a passphrase prompt
//! looks like every other question the toolchain asks: a card with a `▓▓▓`
//! title over a rule, the body, the entry in its own rounded box behind a `❯`,
//! and the key hints sitting on the bottom border.

use std::io;
use std::time::{Duration, Instant};

use crate::secret::Passphrase;
use crate::term::Tty;
use crate::theme::{Theme, BOLD, RESET};

/// The float geometry, matching ai-playbook's `FloatWidthDefault`. Fixed rather
/// than measured: a dialog that changes width with the length of a key's user
/// ID would make every prompt a different shape.
pub const FLOAT_WIDTH: u16 = 57;

/// Below this the dialog stops being readable, and a caller that cannot give us
/// this much should prompt somewhere else rather than draw a broken box.
pub const MIN_WIDTH: u16 = 40;

/// Inside a float the border belongs to tmux — it draws a themed, rounded one
/// from `popup-border-lines`, and a second box around the first is one box too
/// many. So the dialog drops its own frame and takes the two columns and two
/// rows tmux spends on the border off its own size.
pub const FLOAT_PTY_WIDTH: u16 = FLOAT_WIDTH - 2;

const H_PAD: usize = 2; // left/right padding inside the outer border
const BORDER: usize = 2; // outer border, left + right cells
const BOX_PAD_L: usize = 1; // entry box left padding
const ICON_COL: usize = 2; // the key glyph plus its one-space gap
const TITLE_MARK: &str = "▓▓▓ ";
const ENTRY_ICON: char = '\u{10f084}'; // fa-key: this box takes a key, not a command
const MASK: char = '•';

pub enum Outcome {
    Accepted(Passphrase),
    Cancelled,
    /// Nobody answered within `SETTIMEOUT`. Distinct from a cancel: the human
    /// never declined, they were never there.
    TimedOut,
}

/// The key being unlocked, drawn as a labelled tree under its user ID rather
/// than as the run-on sentence gpg words it as.
pub struct KeyInfo {
    pub user_id: String,
    /// Glyph and text, one per branch, in the order they should read.
    pub facts: Vec<(String, String)>,
}

/// One drawn line of the key block. Splitting the block into lines *before*
/// they are styled lets the height be counted without a theme, which is what
/// the float needs when it sizes itself with no terminal in hand.
enum KeyLine {
    UserId(String),
    Fact {
        last: bool,
        glyph: String,
        text: String,
    },
}

/// Who asked for the passphrase — the fact that decides whether to type it.
pub struct Requester {
    /// The process icon, resolved by whoever resolved the process. It is the
    /// same table the tab pills use (`.muxTabIcons` in `home/.chezmoidata/mux.yaml`,
    /// mirrored by zj-hud's `icons::process_icon`), so a request from claude
    /// wears the glyph its tab wears, and an unknown process gets `nf-md-run`.
    pub glyph: String,
    /// Already composed, e.g. `claude · pane %3 (Main:2)`.
    pub label: String,
    /// The request did not come from the pane the human is attached to. This is
    /// the case the line exists for: a line that always looks the same stops
    /// being read, so the quiet case stays muted and this one does not.
    pub elsewhere: bool,
}

pub struct Dialog {
    pub title: Option<String>,
    pub description: Vec<String>,
    pub key: Option<KeyInfo>,
    pub requester: Option<Requester>,
    pub error: Option<String>,
    /// Total canvas width, borders included. The caller picks it so the float
    /// can be opened at the right size before a terminal exists to measure.
    pub width: u16,
    /// Draw our own rounded border. False inside a tmux popup, which paints a
    /// themed one of its own — two borders is one too many.
    pub frame: bool,
    /// How long the dialog may wait for its first useful keystroke before
    /// giving up. The point is not the dialog: an unanswered prompt holds
    /// gpg-agent's global entry lock, so every later request dies too.
    pub timeout: Option<Duration>,
}

/// A run of text and the SGR it is painted in. Rows are built from these so the
/// padding that squares a row off can be computed from what is actually on it.
type Span = (String, String);

fn span(style: &str, text: impl Into<String>) -> Span {
    (style.to_string(), text.into())
}

impl Dialog {
    /// The exact canvas this dialog needs, borders included.
    ///
    /// This is the number the float will be opened with. It exists as a method
    /// rather than an estimate because the whole reason for owning the dialog
    /// is that the program choosing the layout is the one asking for the space.
    pub fn size(&self) -> (u16, u16) {
        (self.width, self.rows() as u16)
    }

    fn inner_width(&self) -> usize {
        let chrome = 2 * H_PAD + if self.frame { BORDER } else { 0 };
        (self.width as usize).saturating_sub(chrome).max(1)
    }

    fn rows(&self) -> usize {
        let inner = self.inner_width();
        let mut rows = 1; // top padding; there is no bottom padding
        if self.title.is_some() {
            rows += 3; // title, rule, inset
        }
        rows += self.body_lines(inner).len();
        if self.key.is_some() {
            rows += 1 + self.key_lines(inner).len(); // inset, then the block
        }
        if let Some(e) = &self.error {
            rows += 1 + wrap(e, inner).len(); // inset, then the message
        }
        if let Some(r) = &self.requester {
            rows += 1 + wrap(&requester_line(r), inner).len();
        }
        rows += 1 + 3 + 1 + 1; // inset, entry box, inset, hint
        rows + if self.frame { 2 } else { 0 }
    }

    fn body_lines(&self, inner: usize) -> Vec<String> {
        self.description
            .iter()
            .flat_map(|line| wrap(line, inner))
            .collect()
    }

    fn key_lines(&self, inner: usize) -> Vec<KeyLine> {
        let Some(key) = &self.key else {
            return Vec::new();
        };
        let mut lines: Vec<KeyLine> = wrap(&key.user_id, inner)
            .into_iter()
            .map(KeyLine::UserId)
            .collect();
        // " ├ " plus the glyph and its space. A fact that would not fit is
        // clipped rather than wrapped: these are key IDs and dates, and a
        // second line of one reads as a second fact.
        let room = inner.saturating_sub(5);
        let last = key.facts.len().saturating_sub(1);
        for (i, (glyph, text)) in key.facts.iter().enumerate() {
            lines.push(KeyLine::Fact {
                last: i == last,
                glyph: glyph.clone(),
                text: text.chars().take(room).collect(),
            });
        }
        lines
    }

    /// Draw, read keys, and return what the human decided.
    pub fn run(&self, tty: &mut Tty, theme: &Theme) -> io::Result<Outcome> {
        let mut pass = Passphrase::new();
        let mut full = false;
        let deadline = self.timeout.map(|d| Instant::now() + d);

        loop {
            self.paint(tty, theme, &pass, full)?;

            // The deadline is against the whole dialog, not each keystroke: a
            // half-typed passphrase left on screen holds the lock exactly as
            // hard as an untouched one.
            if let Some(end) = deadline {
                loop {
                    let left = end.saturating_duration_since(Instant::now());
                    if left.is_zero() {
                        return Ok(Outcome::TimedOut);
                    }
                    // A signal makes select report nothing readable, so only
                    // the clock is allowed to end this wait.
                    if tty.wait_readable(left.as_millis().min(i32::MAX as u128) as i32) {
                        break;
                    }
                }
            }

            let Some(byte) = tty.read_byte()? else {
                return Ok(Outcome::Cancelled);
            };

            match byte {
                b'\r' | b'\n' => return Ok(Outcome::Accepted(pass)),
                0x03 => return Ok(Outcome::Cancelled), // Ctrl-C
                0x1b => {
                    // A lone Esc cancels; anything that continues is a key we do
                    // not implement and must swallow whole. Letting the tail of
                    // a CSI sequence fall through to the printable branch below
                    // is how "1234" becomes "1234[27;8;49~".
                    if tty.wait_readable(ESC_TIMEOUT_MS) {
                        consume_escape_sequence(tty)?;
                    } else {
                        return Ok(Outcome::Cancelled);
                    }
                }
                0x7f | 0x08 => {
                    pass.pop_char();
                    full = false;
                }
                0x15 => {
                    pass.clear();
                    full = false;
                } // Ctrl-U
                0x17 => {
                    pass.pop_word();
                    full = false;
                } // Ctrl-W
                b if b >= 0x20 && b != 0x7f => full = !pass.push(b),
                _ => {}
            }
        }
    }

    fn paint(&self, tty: &Tty, theme: &Theme, pass: &Passphrase, full: bool) -> io::Result<()> {
        let (cols, screen_rows) = tty.size();
        let (w, h) = self.size();
        let left = cols.saturating_sub(w) / 2 + 1;
        let top = screen_rows.saturating_sub(h) / 2 + 1;
        let inner = self.inner_width();

        // A retry is the one moment the dialog has bad news, so it takes the
        // danger variant wholesale — border and title both — the way the rest
        // of the toolchain signals it.
        let accent = if self.error.is_some() {
            &theme.danger
        } else {
            &theme.title
        };
        let edge = if self.error.is_some() {
            &theme.danger
        } else {
            &theme.border
        };

        // The mask is clamped to the entry box: a passphrase longer than the
        // field must not paint over the border, and the count on screen is a
        // display detail rather than a promise about the buffer.
        let field = inner.saturating_sub(BORDER + BOX_PAD_L + ICON_COL);
        let shown = pass.chars().min(field);

        let mut rows: Vec<Vec<Span>> = vec![Vec::new()];
        if let Some(title) = &self.title {
            rows.push(vec![span(
                &format!("{BOLD}{accent}"),
                format!("{TITLE_MARK}{title}"),
            )]);
            rows.push(vec![span(&theme.rule, "━".repeat(inner))]);
            rows.push(Vec::new());
        }
        for line in self.body_lines(inner) {
            rows.push(vec![span(&theme.text, line)]);
        }
        if self.key.is_some() {
            rows.push(Vec::new());
            for line in self.key_lines(inner) {
                rows.push(match line {
                    KeyLine::UserId(text) => vec![span(&theme.text, text)],
                    KeyLine::Fact { last, glyph, text } => vec![
                        span(&theme.hint, if last { " ╰ " } else { " ├ " }),
                        span(&theme.fact, glyph),
                        span(&theme.text, format!(" {text}")),
                    ],
                });
            }
        }
        if let Some(err) = &self.error {
            rows.push(Vec::new());
            for line in wrap(err, inner) {
                rows.push(vec![span(&theme.danger, line)]);
            }
        }
        if let Some(req) = &self.requester {
            let style = if req.elsewhere {
                &theme.alert
            } else {
                &theme.hint
            };
            rows.push(Vec::new());
            for line in wrap(&requester_line(req), inner) {
                rows.push(vec![span(style, line)]);
            }
        }

        rows.push(Vec::new());
        let box_rule = "─".repeat(inner.saturating_sub(BORDER));
        rows.push(vec![span(&theme.field_border, format!("╭{box_rule}╮"))]);
        let entry_index = rows.len();
        rows.push(vec![
            span(&theme.field_border, "│"),
            // The entry glyph follows the title, so a retry turns it red along
            // with everything else instead of leaving one mauve mark behind.
            span(accent, format!("{}{ENTRY_ICON} ", " ".repeat(BOX_PAD_L))),
            span(&theme.input, MASK.to_string().repeat(shown)),
            span(
                &theme.field_border,
                format!("{}│", " ".repeat(field - shown)),
            ),
        ]);
        rows.push(vec![span(&theme.field_border, format!("╰{box_rule}╯"))]);
        rows.push(Vec::new());
        rows.push(if full {
            vec![span(&theme.danger, "maximum length reached")]
        } else {
            hint(theme)
        });

        let mut out = String::from("\x1b[?25l\x1b[2J");
        let mut row = top;
        let mut put = |line: String| {
            out.push_str(&format!("\x1b[{row};{left}H{line}"));
            row += 1;
        };

        if self.frame {
            let rule = "─".repeat(w as usize - BORDER);
            put(format!("{}{edge}╭{rule}╮{RESET}", theme.bg));
        }
        for spans in rows {
            let used: usize = spans.iter().map(|(_, t)| display_width(t)).sum();
            let mut line = String::from(&theme.bg);
            if self.frame {
                line.push_str(edge);
                line.push('│');
            }
            line.push_str(&" ".repeat(H_PAD));
            for (style, text) in spans {
                line.push_str(&style);
                line.push_str(&text);
            }
            line.push_str(&" ".repeat(inner.saturating_sub(used) + H_PAD));
            if self.frame {
                line.push_str(edge);
                line.push('│');
            }
            line.push_str(RESET);
            put(line);
        }
        if self.frame {
            let rule = "─".repeat(w as usize - BORDER);
            put(format!("{}{edge}╰{rule}╯{RESET}", theme.bg));
        }

        // Park the cursor after the last bullet so the human can see where they
        // are typing. The row is the entry's own index rather than a count back
        // from the end, which is how it ended up a line below the box.
        let entry_row = top + if self.frame { 1 } else { 0 } + entry_index as u16;
        let content = left + if self.frame { 1 } else { 0 } + H_PAD as u16;
        let cursor_col = content + (1 + BOX_PAD_L + ICON_COL + shown) as u16;
        out.push_str(&format!("\x1b[{entry_row};{cursor_col}H\x1b[?25h"));

        tty.write(out.as_bytes())
    }
}

const ESC_TIMEOUT_MS: i32 = 50;

/// The glyph and the lead-in, in one place so the height and the drawing cannot
/// disagree about how long the line is.
fn requester_line(req: &Requester) -> String {
    format!("{} requested by {}", req.glyph, req.label)
}

/// The hints, in the shape `pick::hints` defines for every dialog in this repo
/// (`home/dot_local/lib/pick-common.zsh`): key glyph in the key colour, label in
/// the muted one, segments joined by ` · `, a chord written with a plain space
/// between modifier and letter, and an NBSP as the key/label gap. The NBSP is
/// what lets a plain-string colouriser find that boundary; we colour by
/// construction and do not need it, but the shape is the repo's and not ours.
fn hint(theme: &Theme) -> Vec<Span> {
    const NBSP: char = '\u{00a0}';
    let keys = [
        ("\u{f0311}", "submit"),  // md-keyboard-return
        ("\u{f0634} U", "clear"), // md-apple-keyboard-control
        ("\u{f12b7}", "cancel"),  // md-keyboard-esc
    ];
    let mut spans = Vec::new();
    for (i, (key, label)) in keys.into_iter().enumerate() {
        if i > 0 {
            spans.push(span(&theme.hint, " · "));
        }
        spans.push(span(&theme.key, key));
        spans.push(span(&theme.hint, format!("{NBSP}{label}")));
    }
    spans
}

/// Swallow a CSI/SS3 sequence up to and including its final byte.
fn consume_escape_sequence(tty: &Tty) -> io::Result<()> {
    let Some(intro) = tty.read_byte()? else {
        return Ok(());
    };
    if intro != b'[' && intro != b'O' {
        return Ok(()); // Alt-<key>: two bytes, both discarded.
    }
    // Parameter and intermediate bytes run 0x30-0x3f and 0x20-0x2f; the
    // sequence ends at the first byte in 0x40-0x7e.
    while let Some(b) = tty.read_byte()? {
        if (0x40..=0x7e).contains(&b) {
            break;
        }
    }
    Ok(())
}

/// Break `text` to `width` columns on spaces, splitting a word that is too long
/// to fit on a line of its own — a key's user ID can be one unbroken string,
/// and letting it run would paint straight through the border.
fn wrap(text: &str, width: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut line = String::new();
    for word in text.split_whitespace() {
        let mut word = word;
        while display_width(word) > width {
            let head: String = word.chars().take(width).collect();
            if !line.is_empty() {
                out.push(std::mem::take(&mut line));
            }
            word = &word[head.len()..];
            out.push(head);
        }
        if line.is_empty() {
            line = word.to_string();
        } else if display_width(&line) + 1 + display_width(word) <= width {
            line.push(' ');
            line.push_str(word);
        } else {
            out.push(std::mem::replace(&mut line, word.to_string()));
        }
    }
    if !line.is_empty() || out.is_empty() {
        out.push(line);
    }
    out
}

/// Columns a string occupies, near enough for the text this dialog carries.
///
/// Counting characters is exact for the ASCII that gpg descriptions and prompts
/// are made of, and wrong only for wide CJK or combining marks in a key's user
/// ID. The failure mode is a box a column or two wider than needed, which is
/// the harmless direction.
fn display_width(s: &str) -> usize {
    s.chars().count()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dialog() -> Dialog {
        Dialog {
            title: Some("Passphrase".into()),
            description: vec!["line one".into(), "a longer description line".into()],
            key: None,
            requester: None,
            error: None,
            width: FLOAT_WIDTH,
            frame: true,
            timeout: None,
        }
    }

    fn key_info() -> KeyInfo {
        KeyInfo {
            user_id: "\"Example Key <key@example.invalid>\"".into(),
            facts: vec![
                ("\u{f033e}".into(), "4096-bit RSA key".into()),
                ("\u{f00ed}".into(), "created in 2020-01-01".into()),
            ],
        }
    }

    #[test]
    fn the_canvas_is_the_float_width() {
        assert_eq!(dialog().size().0, FLOAT_WIDTH);
        assert_eq!(dialog().inner_width(), 51); // 57 - 2 border - 2*2 padding
    }

    #[test]
    fn a_long_line_wraps_instead_of_widening_the_box() {
        let mut d = dialog();
        d.description = vec!["word ".repeat(40).trim_end().to_string()];
        let tall = d.size();
        assert_eq!(tall.0, FLOAT_WIDTH);
        assert!(tall.1 > dialog().size().1, "wrapped text should add rows");
    }

    #[test]
    fn the_key_block_costs_a_gap_plus_a_row_per_line() {
        let plain = dialog().size().1;
        let mut d = dialog();
        d.key = Some(key_info());
        assert_eq!(d.size().1, plain + 1 + 3); // inset, user ID, two facts
    }

    #[test]
    fn a_fact_too_wide_for_the_dialog_is_clipped_not_wrapped() {
        let mut d = dialog();
        let mut key = key_info();
        key.facts = vec![("\u{f033e}".into(), "x".repeat(200))];
        d.key = Some(key);
        assert_eq!(d.size().1, dialog().size().1 + 1 + 2); // inset, user ID, one fact
    }

    #[test]
    fn the_requester_costs_a_gap_and_a_row() {
        let plain = dialog().size().1;
        let mut d = dialog();
        d.requester = Some(Requester {
            glyph: "\u{10e861}".into(),
            label: "claude · pane %3".into(),
            elsewhere: true,
        });
        assert_eq!(d.size().1, plain + 2);
    }

    #[test]
    fn an_error_makes_the_dialog_taller() {
        let plain = dialog().size().1;
        let mut d = dialog();
        d.error = Some("Bad Passphrase (try 2 of 3)".into());
        assert_eq!(d.size().1, plain + 2); // the inset and the message
    }

    #[test]
    fn dropping_the_frame_keeps_the_width_and_loses_the_border_rows() {
        let framed = dialog().size();
        let mut d = dialog();
        d.frame = false;
        assert_eq!(d.size(), (framed.0, framed.1 - 2));
    }

    #[test]
    fn wrapping_breaks_a_word_too_long_for_a_line() {
        assert_eq!(wrap("abcdefghij", 4), vec!["abcd", "efgh", "ij"]);
        assert_eq!(wrap("one two three", 7), vec!["one two", "three"]);
        assert_eq!(wrap("", 10), vec![""]);
    }
}
