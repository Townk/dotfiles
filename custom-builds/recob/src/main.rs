//! `recobd` entry point: parse the launch shape, bind or adopt the endpoints,
//! then accept (§3).

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use recobd::auth;
use recobd::exposure::Exposure;
use recobd::host::HostIdentity;
use recobd::listen::{self, Bound, DEFAULT_PUBLIC_PORT};
use recobd::log;
use recobd::record::{self, Recorder};
use recobd::session::Ctx;
use recobd::wire::{PROTO, WIRE_VERSION};

/// §5.1: `impl` distinguishes two builds that share a `proto`. Phase 8's build
/// hook passes the chezmoi source hash prefix; a hand-built binary says `dev`.
const IMPL: &str = match option_env!("RECOB_IMPL") {
    Some(id) => id,
    None => concat!("dev-", env!("CARGO_PKG_VERSION")),
};

const USAGE: &str = "\
usage: recobd [--record] [--capture] [--port <n>] [--socket <path>]
              [--no-public] [--no-trusted]

  --record          recording seam (spec §11.1): tee decoded exchanges to
                    RECOB_RECORD_LOG and answer from RECOB_RECORD_SCRIPT
  --capture         observe the pasteboard and write clipboard history rows
                    (spec §14.1/§14.2, macOS only). Opt-in so that nothing —
                    a test daemon above all — touches the live store without
                    being asked to; the production unit passes it at cutover
  --port <n>        public endpoint port (default 2489, loopback only)
  --socket <path>   trusted endpoint socket (default ~/.local/state/cb.sock)
  --no-public       do not serve the public endpoint
  --no-trusted      do not serve the trusted endpoint

With LISTEN_FDS set (systemd socket activation, spec §3.2) the listening
sockets are adopted from fd 3 up and nothing is bound.

Environment:
  RECOB_TIMEOUT_S            exchange timeout in seconds (default 2, spec §5.2)
  RECOB_IMPL                 build identity reported in the capabilities frame
  RECOB_CAPTURE_POLL_MS      capture poll interval (default 500)
  RECOB_CAPTURE_PASTEBOARD   named pasteboard to observe instead of the general
                             one (test/diagnostic seam)
";

struct Args {
    record: bool,
    capture: bool,
    port: u16,
    socket: PathBuf,
    public: bool,
    trusted: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args {
        record: false,
        capture: false,
        port: DEFAULT_PUBLIC_PORT,
        socket: listen::default_trusted_socket(),
        public: true,
        trusted: true,
    };
    let mut argv = std::env::args().skip(1);
    while let Some(arg) = argv.next() {
        match arg.as_str() {
            "--record" => args.record = true,
            "--capture" => args.capture = true,
            "--no-public" => args.public = false,
            "--no-trusted" => args.trusted = false,
            "--port" => {
                let value = argv.next().ok_or("--port needs a number")?;
                args.port = value.parse().map_err(|_| format!("bad port {value:?}"))?;
            }
            "--socket" => {
                args.socket = PathBuf::from(argv.next().ok_or("--socket needs a path")?);
            }
            "--help" | "-h" => return Err(String::new()),
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    if !args.public && !args.trusted {
        return Err("--no-public and --no-trusted leave nothing to serve".to_string());
    }
    // §14.7: the Linux build has no pasteboard to observe. Refusing loudly
    // beats a daemon that silently captures nothing.
    if args.capture && !cfg!(target_os = "macos") {
        return Err("--capture requires macOS (spec §14.7)".to_string());
    }
    Ok(args)
}

fn exchange_timeout() -> Duration {
    match std::env::var("RECOB_TIMEOUT_S") {
        Ok(v) => match v.trim().parse::<f64>() {
            Ok(secs) if secs > 0.0 => Duration::from_secs_f64(secs),
            _ => {
                log!("RECOB_TIMEOUT_S={v:?} is not a positive number; using 2s");
                Duration::from_secs(2)
            }
        },
        Err(_) => Duration::from_secs(2),
    }
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(args) => args,
        Err(msg) => {
            if msg.is_empty() {
                print!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            eprintln!("recobd: {msg}\n\n{USAGE}");
            return ExitCode::FAILURE;
        }
    };

    let bound = match endpoints(&args) {
        Ok(bound) => bound,
        Err(e) => {
            log!("cannot serve: {e}");
            return ExitCode::FAILURE;
        }
    };

    let mut ctx = Ctx::new(
        HostIdentity::resolve(),
        IMPL.to_string(),
        exchange_timeout(),
    );
    // The operator's own configuration, opted into explicitly here: `Ctx::new`
    // leaves it inert so a test can never pick this file up by accident.
    ctx.exposure = Exposure::default();
    if args.record {
        ctx.recorder = Some(Recorder::from_env());
        log!("recording mode (§11.1): decoding with the production decoder");
    }

    // §9.2 bootstrap: the credential is created at startup when absent or
    // invalid, and an endpoint that cannot load or create one refuses to start
    // rather than serving unauthenticated. Only the public endpoint checks a
    // credential — the trusted socket's uid boundary is its credential — so a
    // trusted-only daemon needs no token to start.
    if bound.public.is_some() {
        let token = match auth::load_or_create(&ctx.token_path) {
            Ok(token) => token,
            Err(e) => {
                log!(
                    "cannot serve the public endpoint: no usable credential at {}: {e}",
                    ctx.token_path.display()
                );
                return ExitCode::FAILURE;
            }
        };
        if args.record {
            // §11.1's credential fixture, so a converted spec does not hand-roll
            // the handshake.
            match ctx.host.current() {
                Some(host) => {
                    if let Err(e) = record::install_credential_fixture(&token, &host) {
                        log!("cannot install the credential fixture: {e}");
                        return ExitCode::FAILURE;
                    }
                }
                None => log!("no host identity, so no credential fixture was written"),
            }
        }
    }

    // §14.2: the capture loop, opted into with --capture. The tracker is
    // shared so the loop recognizes the daemon's own future writes (§6.2);
    // Phase 4's clip operations take the other end of it.
    #[cfg(target_os = "macos")]
    if args.capture {
        let tracker = std::sync::Arc::new(recobd::platform::RegtypeTracker::default());
        let config = recobd::platform::macos::CaptureConfig::from_env();
        if let Err(e) = recobd::platform::macos::start_capture(config, tracker) {
            log!("cannot start the capture loop: {e}");
            return ExitCode::FAILURE;
        }
    }

    log!(
        "wire {WIRE_VERSION} proto {PROTO} impl {IMPL} host {}",
        ctx.host.current().unwrap_or_else(|| "<unresolved>".into())
    );

    if let Err(e) = listen::serve_forever(bound, Arc::new(ctx)) {
        log!("accept loop stopped: {e}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

/// §3.2: adopt the listeners when `LISTEN_FDS` is set, bind them when it is not,
/// so the same binary runs under systemd, under launchd, and from a terminal.
fn endpoints(args: &Args) -> std::io::Result<Bound> {
    if let Some(activated) = listen::adopt_activated()? {
        return Ok(activated);
    }
    let mut bound = Bound::default();
    if args.public {
        bound.public = Some(listen::bind_public(args.port)?);
    }
    if args.trusted {
        bound.trusted = Some(listen::bind_trusted(&args.socket)?);
    }
    Ok(bound)
}
