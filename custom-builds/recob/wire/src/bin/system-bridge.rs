//! `system-bridge` — the bridge's own generic client: one connection, one
//! §4.3 request, one reply, any operation. It exists so shell callers reach
//! `window.fullscreen.*`, `osd.notify`, `clip.get` and the rest without
//! `system-clip` growing verbs that are not clipboard ones — the daemon's
//! §9.3 policy table is the control, not this binary's surface.
//!
//! Installed to `~/.local/libexec/system-bridge`, off PATH: it is plumbing
//! the `clipbridge::` zsh wrapper execs, not a command a human types. The
//! wrapper is a *caller* of this client, not a client itself — this binary
//! spawns nothing (§8).
//!
//!     system-bridge call <op> [name=value]... [--stdin <name>]
//!                    [--peer] [--action] [--raw <field>]
//!
//! Fields: `name=value` arguments carry scalars; `--stdin <name>` reads that
//! one field's value as raw bytes from standard input (text that may hold
//! ANSI, NUL-joined path lists). Replies print every field as `name=<hex>`,
//! one per line — the recorder's own framing, binary-safe, trivially decoded
//! from zsh — or exactly one field's raw bytes under `--raw`.

use std::io::Read;
use std::process::ExitCode;

use recob_wire::cli::{public_session, trusted_session, PublicBridge};
use recob_wire::client::{ClientError, ClientStream, Session};
use recob_wire::wire::Fields;

const PROGRAM: &str = "system-bridge";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("call") => call(&args[2..]),
        Some("probe") => probe(&args[2..]),
        _ => {
            eprintln!(
                "usage: {PROGRAM} call <op> [name=value]... [--stdin <name>] \
                 [--peer] [--action] [--raw <field>]\n\
                        {PROGRAM} probe <host> <port>"
            );
            ExitCode::FAILURE
        }
    }
}

/// §6.1: reachability is not an operation. The probe is §5.2's connect
/// result — `ECONNREFUSED` means down, anything else means up, which is
/// strictly more accurate than a connect scan that reports down for a bound
/// but saturated listener. Never an authenticated round trip.
fn probe(args: &[String]) -> ExitCode {
    let (Some(host), Some(port)) = (args.first(), args.get(1)) else {
        return fail(format!("usage: {PROGRAM} probe <host> <port>"));
    };
    let Ok(port) = port.parse::<u16>() else {
        return fail(format!("{PROGRAM}: not a port: {port}"));
    };
    match recob_wire::client::dial(host, port, std::time::Duration::from_secs(1)) {
        recob_wire::client::Dial::Refused => ExitCode::FAILURE,
        _ => ExitCode::SUCCESS,
    }
}

struct Invocation {
    op: String,
    fields: Vec<(String, Vec<u8>)>,
    stdin_field: Option<String>,
    peer: bool,
    action: bool,
    raw: Option<String>,
}

fn parse(args: &[String]) -> Result<Invocation, String> {
    let mut invocation = Invocation {
        op: String::new(),
        fields: Vec::new(),
        stdin_field: None,
        peer: false,
        action: false,
        raw: None,
    };
    let mut words = args.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--peer" => invocation.peer = true,
            "--action" => invocation.action = true,
            "--stdin" => {
                let name = words
                    .next()
                    .ok_or_else(|| format!("{PROGRAM}: --stdin needs a field name"))?;
                if invocation.stdin_field.is_some() {
                    return Err(format!("{PROGRAM}: --stdin may name only one field"));
                }
                invocation.stdin_field = Some(name.clone());
            }
            "--raw" => {
                let name = words
                    .next()
                    .ok_or_else(|| format!("{PROGRAM}: --raw needs a field name"))?;
                if invocation.raw.is_some() {
                    return Err(format!("{PROGRAM}: --raw may name only one field"));
                }
                invocation.raw = Some(name.clone());
            }
            _ if invocation.op.is_empty() => invocation.op = word.clone(),
            _ => {
                let Some((name, value)) = word.split_once('=') else {
                    return Err(format!(
                        "{PROGRAM}: field arguments are name=value, got {word:?}"
                    ));
                };
                if name.is_empty() {
                    return Err(format!("{PROGRAM}: a field needs a name: {word:?}"));
                }
                invocation
                    .fields
                    .push((name.to_string(), value.as_bytes().to_vec()));
            }
        }
    }
    if invocation.op.is_empty() {
        return Err(format!("{PROGRAM}: call needs an operation name"));
    }
    // Duplicates are `bad-field` on the wire (§4.3); catching the caller's
    // slip here names it better than the server's shape error would.
    let mut names: Vec<&str> = invocation
        .fields
        .iter()
        .map(|(name, _)| name.as_str())
        .chain(invocation.stdin_field.as_deref())
        .collect();
    names.sort_unstable();
    if let Some(pair) = names.windows(2).find(|pair| pair[0] == pair[1]) {
        return Err(format!("{PROGRAM}: field {} given twice", pair[0]));
    }
    if invocation.fields.iter().any(|(name, _)| name == "op")
        || invocation.stdin_field.as_deref() == Some("op")
    {
        return Err(format!(
            "{PROGRAM}: op is the operation argument, not a field"
        ));
    }
    Ok(invocation)
}

fn call(args: &[String]) -> ExitCode {
    let invocation = match parse(args) {
        Ok(invocation) => invocation,
        Err(message) => return fail(message),
    };

    let mut request = Fields::new().with("op", invocation.op.as_bytes().to_vec());
    for (name, value) in &invocation.fields {
        request.push(name, value.clone());
    }
    if let Some(name) = &invocation.stdin_field {
        let mut value = Vec::new();
        if let Err(e) = std::io::stdin().read_to_end(&mut value) {
            return fail(format!("{PROGRAM}: cannot read stdin: {e}"));
        }
        request.push(name, value);
    }

    let reply = if invocation.peer {
        match public_session(PROGRAM) {
            Err(message) => return fail(message),
            Ok(PublicBridge::Absent) => {
                return fail(format!(
                    "{PROGRAM}: clipboard bridge not reachable on 127.0.0.1:{} \
                     (reverse SSH tunnel down?)",
                    recob_wire::cli::bridge_port()
                ))
            }
            Ok(PublicBridge::Session(mut session)) => {
                exchange(&mut session, &request, invocation.action)
            }
        }
    } else {
        match trusted_session(PROGRAM) {
            Err(message) => return fail(message),
            Ok(mut session) => exchange(&mut session, &request, invocation.action),
        }
    };
    let reply = match reply {
        Ok(reply) => reply,
        Err(message) => return fail(message),
    };

    render(&reply, invocation.raw.as_deref())
}

fn exchange<S: ClientStream>(
    session: &mut Session<S>,
    request: &Fields,
    action: bool,
) -> Result<Fields, String> {
    session.exchange(request, action).map_err(|e| match e {
        // Rule 3: the code is the contract, so it rides along in a fixed,
        // greppable position; the free-form message stays human-first.
        ClientError::Server { code, message } => format!("{PROGRAM}: {message} ({code})"),
        other => format!("{PROGRAM}: {other}"),
    })
}

fn render(reply: &Fields, raw: Option<&str>) -> ExitCode {
    use std::io::Write;
    let mut stdout = std::io::stdout();
    let outcome = match raw {
        Some(field) => match reply.get(field) {
            Some(value) => stdout.write_all(value),
            None => return fail(format!("{PROGRAM}: the reply carried no {field} field")),
        },
        None => {
            let mut out = Vec::new();
            for name in reply.names() {
                let value = reply.get(name).unwrap_or_default();
                out.extend_from_slice(name.as_bytes());
                out.push(b'=');
                for byte in value {
                    out.extend_from_slice(format!("{byte:02x}").as_bytes());
                }
                out.push(b'\n');
            }
            stdout.write_all(&out)
        }
    };
    match outcome.and_then(|()| stdout.flush()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => fail(format!("{PROGRAM}: cannot write reply: {e}")),
    }
}

fn fail(message: String) -> ExitCode {
    eprintln!("{message}");
    ExitCode::FAILURE
}
