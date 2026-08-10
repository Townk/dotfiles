//! Turning gpg's description into the key block the dialog draws.
//!
//! gpg — not gpg-agent — builds the text, from this template in the binary:
//!
//! ```text
//! "%.*s"
//! %u-bit %s key, ID %s,
//! created %s%s.
//! ```
//!
//! preceded by a sentence like *Please enter the passphrase to unlock the
//! OpenPGP secret key:* and a blank line. So the description is a paragraph
//! followed by a quoted user ID followed by a run-on sentence of facts, and the
//! dialog draws the facts as a labelled tree instead.
//!
//! **The parse is allowed to fail, and failing well is the requirement.** This
//! is gpg's prose, in gpg's locale, and it can be reworded by an upstream
//! release or translated out from under us. Every path that does not find the
//! expected shape falls back to drawing the description exactly as sent, which
//! is what the stock pinentry does and is never wrong — only plainer.

use crate::dialog::KeyInfo;

/// nf-md-lock — the algorithm and size.
const G_ALGO: &str = "\u{f033e}";
/// fa-id-card, from the Font Awesome plane this repo's font build relocates.
const G_ID: &str = "\u{10f2bb}";
/// nf-md-calendar — when it was made.
const G_CREATED: &str = "\u{f00ed}";

/// The description split into the paragraph above the key block and the key
/// block itself. `None` for the key means "draw the rest verbatim".
pub struct Described {
    pub intro: Vec<String>,
    pub key: Option<KeyInfo>,
}

pub fn parse(desc: &str) -> Described {
    let lines: Vec<&str> = desc.lines().collect();

    // The user ID is the anchor: a line that is entirely a quoted string.
    // Without it there is no key block to build, and everything is intro.
    let anchor = lines
        .iter()
        .position(|l| is_quoted(l.trim()))
        .filter(|&i| i + 1 < lines.len());

    let Some(anchor) = anchor else {
        return Described {
            intro: trimmed(&lines),
            key: None,
        };
    };

    let facts = facts_from(&lines[anchor + 1..]);
    if facts.is_empty() {
        return Described {
            intro: trimmed(&lines),
            key: None,
        };
    }

    Described {
        intro: trimmed(&lines[..anchor]),
        key: Some(KeyInfo {
            user_id: lines[anchor].trim().to_string(),
            facts,
        }),
    }
}

fn is_quoted(l: &str) -> bool {
    l.len() >= 2 && l.starts_with('"') && l.ends_with('"')
}

/// Drop the blank line gpg puts after the opening sentence — the dialog spaces
/// its own sections, and an extra empty row inside a paragraph reads as a
/// mistake.
fn trimmed(lines: &[&str]) -> Vec<String> {
    let mut out: Vec<String> = lines.iter().map(|l| l.trim().to_string()).collect();
    while out.last().is_some_and(|l| l.is_empty()) {
        out.pop();
    }
    while out.first().is_some_and(|l| l.is_empty()) {
        out.remove(0);
    }
    out.retain(|l| !l.is_empty());
    out
}

/// `4096-bit RSA key, ID 0123…, created 2020-01-01.` becomes one fact per
/// clause. The wording is kept exactly as gpg wrote it: rewriting "created X"
/// into something that reads better would be splicing our English into a string
/// that may already have been translated.
fn facts_from(tail: &[&str]) -> Vec<(String, String)> {
    let joined = tail
        .iter()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let joined = joined.trim_end_matches('.');

    joined
        .split(", ")
        .map(str::trim)
        .filter(|c| !c.is_empty())
        .map(|clause| (glyph_for(clause).to_string(), clause.to_string()))
        .collect()
}

/// Matched on the shape gpg produces, and deliberately loose: an unrecognised
/// clause still gets drawn, wearing the generic key glyph, because dropping a
/// fact about the key you are about to unlock is worse than an imperfect icon.
fn glyph_for(clause: &str) -> &'static str {
    let lower = clause.to_ascii_lowercase();
    if lower.starts_with("id ") {
        G_ID
    } else if lower.starts_with("created") {
        G_CREATED
    } else {
        G_ALGO
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Exactly what gpg sends, assembled from the format strings in the
    /// installed binary rather than from memory.
    const REAL: &str = "Please enter the passphrase to unlock the OpenPGP secret key:\n\
                        \n\
                        \"Example Key <key@example.invalid>\"\n\
                        4096-bit RSA key, ID 0123456789ABCDEF,\n\
                        created 2020-01-01.";

    #[test]
    fn the_real_description_becomes_a_paragraph_and_three_facts() {
        let d = parse(REAL);
        assert_eq!(
            d.intro,
            vec!["Please enter the passphrase to unlock the OpenPGP secret key:"]
        );
        let key = d.key.expect("a key block");
        assert_eq!(key.user_id, "\"Example Key <key@example.invalid>\"");
        assert_eq!(
            key.facts,
            vec![
                (G_ALGO.to_string(), "4096-bit RSA key".to_string()),
                (G_ID.to_string(), "ID 0123456789ABCDEF".to_string()),
                (G_CREATED.to_string(), "created 2020-01-01".to_string()),
            ]
        );
    }

    /// gpg appends the primary key's ID for a subkey, inside the same sentence.
    #[test]
    fn a_subkey_keeps_its_main_key_clause() {
        let desc = "Please enter the passphrase:\n\n\"K <k@e.invalid>\"\n\
                    255-bit EDDSA key, ID AAAA,\ncreated 2024-02-03 (main key ID BBBB).";
        let key = parse(desc).key.expect("a key block");
        assert_eq!(key.facts.len(), 3);
        assert_eq!(key.facts[2].1, "created 2024-02-03 (main key ID BBBB)");
    }

    /// The failure mode that matters: unrecognised prose is drawn, not dropped.
    #[test]
    fn a_description_with_no_quoted_user_id_stays_verbatim() {
        let d = parse("Please enter the passphrase for decryption.");
        assert!(d.key.is_none());
        assert_eq!(d.intro, vec!["Please enter the passphrase for decryption."]);
    }

    #[test]
    fn a_user_id_with_nothing_after_it_is_not_a_key_block() {
        let d = parse("Enter passphrase\n\n\"Only A Name\"");
        assert!(d.key.is_none(), "no facts means no tree");
        assert_eq!(d.intro, vec!["Enter passphrase", "\"Only A Name\""]);
    }

    /// A clause we do not recognise still appears, with the generic glyph.
    #[test]
    fn an_unknown_clause_is_kept_rather_than_dropped() {
        let desc = "Enter:\n\n\"K <k@e.invalid>\"\nbrand new kind of key, ID CCCC.";
        let key = parse(desc).key.expect("a key block");
        assert_eq!(
            key.facts[0],
            (G_ALGO.to_string(), "brand new kind of key".to_string())
        );
        assert_eq!(key.facts[1].0, G_ID);
    }

    #[test]
    fn the_blank_line_gpg_sends_does_not_become_an_empty_row() {
        let d = parse(REAL);
        assert!(!d.intro.iter().any(|l| l.is_empty()));
    }
}
