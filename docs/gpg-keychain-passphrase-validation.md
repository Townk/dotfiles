# What the pinentry converge loop can and cannot verify

Notes from diagnosing the 2026-09-11 `system-update` output. The
protection filter described below is implemented; the residual gap at the
end is not.

## The reminder that could never be satisfied

`system-pinentry-setup` warned, every run, that seven keygrips had no
stored passphrase and should be signed once at the console. Six were
noise from disabled keys and encryption-only subkeys, fixed by the
capability filter in `0986f978`. The seventh was the work signing key,
and signing it at the console did not help — the item never appeared.

The key has **no passphrase**. `gpg-connect-agent` reports this directly
in the protection field of `keyinfo`:

```
S KEYINFO AE325672…  D - - - C - - -     ← C = clear, no passphrase
S KEYINFO C1DCAFD5…  D - - 1 P - - -     ← P = passphrase-protected
```

Confirmed independently: an empty passphrase signs with that key. gpg
therefore never raises a pinentry for it, nothing is ever offered for
saving, and `security find-generic-password` can never succeed. The loop
was asking for something that cannot exist.

Both halves of that key (primary and encryption subkey) read `C`. It was
generated that way rather than stripped afterwards — shell history records
a `gpg --quick-generate-key` on 2026-09-09 with no passphrase supplied —
and `import_gpg_document` therefore lands it unprotected on every machine
it runs on. That is a deliberate choice for this key, not a defect,
recorded here so the next reader does not "fix" it.

The loop now skips any grip the agent reports as `C`. An agent that will
not answer yields an empty list, which filters nothing and restores the
previous behaviour.

## How to actually test a passphrase, and the trap in doing so

This wasted a diagnosis during the incident. A loopback signature is the
only way to prove a passphrase unlocks a key — there is no offline
comparison — but the obvious form of the command lies:

```sh
# WRONG: /etc/hostname does not exist on macOS. gpg fails with
# "No such file or directory", which a naive check reads as a
# rejected passphrase.
… | gpg --pinentry-mode loopback --passphrase-fd 0 --clearsign /etc/hostname
```

Sign a file you just created, and always include a control run with a
deliberately wrong passphrase so you can see what a real rejection looks
like (`gpg: signing failed: Bad passphrase`) before trusting a pass:

```sh
d=$(mktemp -d); echo test >"$d/msg"
exec 3< <(security find-generic-password -s GnuPG -a "$grip" -w | tr -d '\n')
gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 \
    --local-user "$key" --clearsign -o /dev/null "$d/msg"
exec 3<&-
```

Feeding the secret on fd 3 keeps it out of argv and off disk. Note that
`security -w` renders a non-UTF-8 password as hex, so a binary
passphrase would fail this test spuriously.

## Why a keychain fault is hard to notice

`gpg-agent` here runs `default-cache-ttl 86400`. One passphrase entered
by hand covers a day of signing, so the keychain path is consulted only
on a cold cache. A fault in it surfaces as an occasional unexplained
prompt rather than a clear failure, and `keyinfo`'s cached field is the
quickest way to tell which source actually served a signature.

Also worth knowing when reading logs: `pinentry-touchid` delegates to
`pinentry-mac` whenever LocalAuthentication cannot run, and reports
nothing when it does. The sensor was in fact unreachable during the
incident — an external Touch ID button that needed replugging — so every
prompt arrived as a GUI or curses password box, and the `No passphrase
given` and `Bad passphrase` errors came from a non-interactive context
unable to answer one. The stored value was correct throughout; neither
error indicts it.

`presence` called that lane `touchid` regardless, because it enumerated
devices rather than asking whether one could authenticate — a wedged
button still appears in `hidutil list`, and a laptop's built-in sensor
stays in the IO registry behind a closed lid. It now gates the lane on a
LocalAuthentication probe (`touchid-available`), which returned false
while the button was wedged and true once it was replugged, so an
unusable sensor yields `gui` instead.

## Residual gap, not addressed

`--keychain-check` asks whether the keychain answered, not whether the
answer works:

```rust
let served = if interactive { keychain::grant(grip) } else { keychain::lookup(grip).is_some() };
```

A stale or truncated item passes, and the converge summary would report
the stack healthy. No such item was found on this machine — the one
suspected of it was verified correct — so this is a latent risk rather
than an observed bug.

Leaving it alone is deliberate. `--keychain-check` runs on the password
path, where its job is "would a read succeed right now, without
interaction"; making it sign would put a private-key operation inside a
probe used during password handling. If it ever needs covering, the check
belongs in `system-pinentry-setup` as a separate step over signing-capable,
protected grips, using the recipe above. The cost to weigh is that
`PRESET_PASSPHRASE` via the agent needs `allow-preset-passphrase` in
`gpg-agent.conf`, which widens what any local process can ask the agent
to cache.
