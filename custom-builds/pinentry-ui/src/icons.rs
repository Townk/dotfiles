//! The glyph for a process, from the table that paints the tab pills.
//!
//! Read from `~/.config/mux/tab-icons.data` for the same reason `theme.rs`
//! reads the palette off disk: this process is spawned by gpg-agent, whose
//! environment carries nothing an interactive shell would have exported, and
//! the alternative — baking the table in at compile time — would mean a new
//! entry in `mux.yaml` reached the tab pills on `chezmoi apply` and this dialog
//! only after somebody remembered to rebuild.

/// The glyph for `name`, or the table's `#default` for anything unlisted.
///
/// Never fails. A host with no generated table gets the same generic run glyph
/// the table would have given, so the dialog is drawn either way — an icon is
/// not worth refusing to ask for a passphrase over.
pub fn glyph_for(name: &str) -> String {
    read_table()
        .and_then(|t| lookup(&t, name))
        .unwrap_or_else(|| FALLBACK.to_string())
}

/// nf-md-run, the same glyph `muxTabIconDefault` holds. Duplicated here only
/// for the case where the table is missing entirely.
const FALLBACK: &str = "\u{f070e}";

fn read_table() -> Option<String> {
    let home = std::env::var_os("HOME")?;
    let mut path = std::path::PathBuf::from(home);
    path.push(".config/mux/tab-icons.data");
    std::fs::read_to_string(path).ok()
}

/// `name`'s glyph, else the `#default` record, else None.
fn lookup(table: &str, name: &str) -> Option<String> {
    let mut default = None;
    for line in table.lines() {
        let Some((key, glyph)) = line.split_once('\t') else {
            continue;
        };
        let glyph = glyph.trim();
        if glyph.is_empty() {
            continue;
        }
        if key == name {
            return Some(glyph.to_string());
        }
        if key == "#default" {
            default = Some(glyph.to_string());
        }
    }
    default
}

#[cfg(test)]
mod tests {
    use super::*;

    const TABLE: &str = "# a comment line with no tab\n\
                         #default\t\u{f070e}\n\
                         claude\t\u{10e861}\n\
                         agent\t\u{10fb00}\n";

    #[test]
    fn finds_a_listed_process() {
        assert_eq!(lookup(TABLE, "claude").unwrap(), "\u{10e861}");
        assert_eq!(lookup(TABLE, "agent").unwrap(), "\u{10fb00}");
    }

    #[test]
    fn an_unlisted_process_gets_the_default() {
        assert_eq!(lookup(TABLE, "some-new-tool").unwrap(), "\u{f070e}");
    }

    /// The comment block at the top of the generated file is prose, and one of
    /// its lines mentions the `#default` key. Only TAB-separated records count.
    #[test]
    fn prose_is_not_a_record() {
        assert!(lookup("just words about #default and claude\n", "claude").is_none());
    }

    /// The real table is the one shipped by `chezmoi apply`; parsing our own
    /// invented sample would prove nothing about the projection.
    #[test]
    fn the_generated_table_answers_for_a_known_agent() {
        let Some(table) = read_table() else {
            return; // not applied on this host
        };
        assert_eq!(lookup(&table, "claude").unwrap(), "\u{10e861}");
        assert_eq!(lookup(&table, "nothing-is-called-this").unwrap(), FALLBACK);
    }
}
