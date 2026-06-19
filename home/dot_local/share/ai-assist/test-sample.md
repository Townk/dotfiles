# ai-assist — live button test

This pane was rendered by **ai-assist-test** (no agent involved). Use it to verify
the code-block buttons and the action-broker end-to-end.

## What to try

- **copy** (yellow icon): click it, or press **Space** then the floating red label,
  then paste somewhere to confirm the block is on your clipboard.
- **play** (green `⏵`, shell blocks only): click it, or Space + its label — it should
  type the command into the pane you triggered ai-assist from and run it.

## Shell block — play + copy

```sh
echo "ai-assist play works ✓"
echo "...and multi-line runs too"
```

## Another shell block (bash) — play + copy

```bash
pwd && ls -la | head -n 5
```

## Non-shell block — copy only (no play)

```python
def greet(name: str) -> str:
    return f"hello, {name}"
```

## A long line — horizontal scroll with h/l

```go
func main() { fmt.Println("a deliberately long line ......................................................................... end") }
```

> [!tip]
> If both copy and play work here, the whole interactive panel — pager buttons,
> hint mode, FIFO, and the shell broker — is wired correctly.
