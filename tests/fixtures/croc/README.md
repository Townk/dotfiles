# croc sender output fixtures

`live-sender-11.2.1.*` — what `croc 11.2.1 --ignore-stdin --disable-clipboard
--throttleUpload 2M --relay <loopback> --yes send payload.bin` prints on a PIPE
(not a tty), the way share runs it under job::. Captured 2026-09-29 over a
loopback `croc relay`, 16 MiB random payload, receiver started 5 s after the
sender. `--throttleUpload 2M` stretches the transfer to ~6 s so it holds many
real percent records.

- `.raw`      the byte stream, CR/LF preserved (scrub below applied)
- `.pre`      records before the `Sending (->` record (split on CR/LF, empties dropped)
- `.transfer` the `Sending (->[peer]:port)` record and everything after it

Boundary rule: croc prints `Hashing <file> NN% |...|` progress at startup,
before any peer connects, so `.pre` contains `%` records. They all start with
`Hashing ` and must be ignored. The connect signal is the `Sending (->[..]:..)`
record; only percent records after it (`<file> NN% |...|`) are transfer progress.

Redraw behaviour: progress redraws with `\r` and no `\n` (497 CRs, 14 LFs in
`.raw`); the LFs are the code/instructions block and the `Sending (->` record.

Scrub: the peer address in `Sending (->[..]:port)` is rewritten to the RFC 3849
documentation address `[2001:db8::2]:9009`; the scratch dir path is rewritten to
`/tmp/croc-capture`. The relay is `127.0.0.1`; the code phrase is a throwaway.

Redo for a new croc version with the same command shape and keep the old files
until share::croc_pct passes against both.
