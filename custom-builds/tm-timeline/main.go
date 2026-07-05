// tm-timeline — the scrub-session timeline pane (spec 2026-07-04 §5.1).
//
// Single purpose (pty-frame pattern): raw-mode input, event-driven truecolor
// rendering, resize handling, near-instant focus tracking. All session LOGIC
// stays in shell: stepping/apply shell out to `system-backup-tm ctl|apply`,
// and this program only reflects the session dir's state files.
//
//	tm-timeline [flags] <session-dir>
//
// The wrapper passes theme colors from the single-source palette as flags —
// this binary hardcodes no theme values.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/term"
)

const (
	reset = "\x1b[0m"
	dim   = "\x1b[2m"
	bwh   = "\x1b[1;37m"
	red   = "\x1b[31m"
	green = "\x1b[32m"
	yellw = "\x1b[33m"
)

func sgr(hex string, bg bool) string {
	h := strings.TrimPrefix(hex, "#")
	if len(h) != 6 {
		return ""
	}
	r, _ := strconv.ParseUint(h[0:2], 16, 8)
	g, _ := strconv.ParseUint(h[2:4], 16, 8)
	b, _ := strconv.ParseUint(h[4:6], 16, 8)
	mode := 38
	if bg {
		mode = 48
	}
	return fmt.Sprintf("\x1b[%d;2;%d;%d;%dm", mode, r, g, b)
}

type rung struct{ epoch int64 }

func readLadder(s string) []rung {
	data, err := os.ReadFile(filepath.Join(s, "ladder"))
	if err != nil {
		return nil
	}
	var out []rung
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		f := strings.Split(line, "\t")
		if len(f) < 2 {
			continue
		}
		e, err := strconv.ParseInt(f[1], 10, 64)
		if err == nil {
			out = append(out, rung{epoch: e})
		}
	}
	return out
}

func readTrim(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// focused reports whether this pane is zellij's focused pane.
func focused() bool {
	pane := os.Getenv("ZELLIJ_PANE_ID")
	if os.Getenv("ZELLIJ") == "" || pane == "" {
		return true
	}
	out, err := exec.Command("zellij", "action", "list-clients").Output()
	if err != nil {
		return true
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) < 2 {
		return true
	}
	f := strings.Fields(lines[1])
	return len(f) >= 2 && f[1] == "terminal_"+pane
}

type ui struct {
	sess, anchor, ctlBin          string
	activeBG, inactiveBG          string
	keyFG, hintFG, titleFG, sepFG string
	ladder                        []rung
	rungIdx                       int
	focus                         bool
	w, h                          int
}

// sepLine renders a full-width rule in the theme separator color
// (falling back to terminal dim when the palette flag is absent).
func (u *ui) sepLine() string {
	c := u.sepFG
	if c == "" {
		c = dim
	}
	n := u.w - 2
	if n < 1 {
		n = 1
	}
	return " " + c + strings.Repeat("━", n) + reset + " \x1b[K\r\n"
}

func (u *ui) frame() string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf(" %s\U0010F1DA Snapshots%s\x1b[K\r\n", u.titleFG, reset))
	b.WriteString(u.sepLine())

	bg := u.inactiveBG
	if u.focus {
		bg = u.activeBG
	}
	width := u.w
	height := u.h - 5
	if height < 3 {
		height = 3
	}

	type row struct {
		text string
		rung int
	}
	var rows []row
	for i, r := range u.ladder {
		t := time.Unix(r.epoch, 0)
		date := t.Format("Mon, Jan 2 2006")
		clock := t.Format("03:04 pm")
		gc := yellw
		if i+1 < u.rungIdx {
			gc = red
		} else if i+1 == u.rungIdx {
			gc = green
		}
		// The time row's bar continues the line toward the next rung;
		// the LAST rung has nothing below it — no dangling bar.
		tg := "┃"
		if i+1 == len(u.ladder) {
			tg = " "
		}
		if i+1 == u.rungIdx && bg != "" {
			pad1 := strings.Repeat(" ", max(0, width-3-len(date)))
			pad2 := strings.Repeat(" ", max(0, width-3-len(clock)))
			rows = append(rows,
				row{bg + " " + gc + "●" + reset + bg + " " + date + pad1 + reset, i + 1},
				row{bg + " " + gc + tg + reset + bg + " " + clock + pad2 + reset, i + 1})
		} else {
			rows = append(rows,
				row{" " + gc + "●" + reset + " " + date, i + 1},
				row{" " + gc + tg + reset + " " + dim + clock + reset, i + 1})
		}
		if i+1 < len(u.ladder) {
			cc := yellw
			if i+1 < u.rungIdx {
				cc = red
			}
			rows = append(rows, row{" " + cc + "┃" + reset, 0})
		}
	}

	first := 0
	if len(rows) > height {
		cur := 0
		for i, r := range rows {
			if r.rung == u.rungIdx {
				cur = i
				break
			}
		}
		first = cur - height/2
		if first < 0 {
			first = 0
		}
		if first+height > len(rows) {
			first = len(rows) - height
		}
	}
	last := min(first+height, len(rows))
	for i := first; i < last; i++ {
		if len(rows) > height && ((i == first && first > 0) || (i == last-1 && last < len(rows))) {
			b.WriteString(" " + dim + "⋮" + reset + "\x1b[K\r\n")
		} else {
			b.WriteString(rows[i].text + "\x1b[K\r\n")
		}
	}

	// Hints mirror the explore lens footer verbatim (session-wide
	// contract: Shift+K/J scrub from ANY pane, so the shift glyphs are
	// honest here too even though this pane also takes plain j/k).
	k, h := u.keyFG, u.hintFG
	b.WriteString(u.sepLine())
	b.WriteString(fmt.Sprintf(" %s\U000F0636 K%s%s newer %s%s· %s%s\U000F0636 J%s%s older%s\x1b[K\r\n   %sQ%s%s quit  %s%s· %s%s\U000F0636 A%s%s apply%s",
		k, reset, h, reset, h, reset, k, reset, h, reset,
		k, reset, h, reset, h, reset, k, reset, h, reset))
	return b.String()
}

func (u *ui) draw() {
	fmt.Print("\x1b[?2026h\x1b[H" + u.frame() + "\x1b[J\x1b[?2026l")
}

func (u *ui) ctl(op string) {
	cmd := exec.Command(u.ctlBin, "ctl", u.sess, op)
	cmd.Stdout, cmd.Stderr = nil, nil
	go func() { _ = cmd.Run() }()
}

func main() {
	activeBG := flag.String("active-bg", "", "highlight bg (focused), #rrggbb")
	inactiveBG := flag.String("inactive-bg", "", "highlight bg (unfocused), #rrggbb")
	keyFG := flag.String("key-fg", "", "footer key color, #rrggbb")
	hintFG := flag.String("hint-fg", "", "footer hint color, #rrggbb")
	titleFG := flag.String("title-fg", "", "pane title color, #rrggbb")
	sepFG := flag.String("sep-fg", "", "separator rule color, #rrggbb")
	flag.Parse()
	sess := flag.Arg(0)
	if sess == "" {
		fmt.Fprintln(os.Stderr, "usage: tm-timeline [flags] <session-dir>")
		os.Exit(2)
	}

	ctlBin := os.Getenv("BKP_TM_BIN")
	if ctlBin == "" {
		home, _ := os.UserHomeDir()
		ctlBin = filepath.Join(home, ".local/bin/system-backup-tm")
	}

	u := &ui{
		sess: sess, ctlBin: ctlBin,
		anchor:     readTrim(filepath.Join(sess, "anchor")),
		activeBG:   sgr(*activeBG, true),
		inactiveBG: sgr(*inactiveBG, true),
		keyFG:      sgr(*keyFG, false),
		hintFG:     sgr(*hintFG, false),
		titleFG:    sgr(*titleFG, false),
		sepFG:      sgr(*sepFG, false),
		ladder:     readLadder(sess),
		rungIdx:    1,
		focus:      true,
	}
	if len(u.ladder) == 0 {
		fmt.Fprintln(os.Stderr, "tm-timeline: empty ladder")
		os.Exit(1)
	}

	old, err := term.MakeRaw(int(os.Stdin.Fd()))
	if err == nil {
		defer term.Restore(int(os.Stdin.Fd()), old)
	}
	fmt.Print("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l")
	defer fmt.Print("\x1b[?25h\x1b[?1049l")

	keys := make(chan byte, 16)
	go func() {
		buf := make([]byte, 8)
		for {
			n, err := os.Stdin.Read(buf)
			if err != nil {
				close(keys)
				return
			}
			s := string(buf[:n])
			switch {
			case strings.Contains(s, "\x1b[A"):
				keys <- 'k'
			case strings.Contains(s, "\x1b[B"):
				keys <- 'j'
			default:
				for _, c := range buf[:n] {
					keys <- c
				}
			}
		}
	}()

	winch := make(chan os.Signal, 1)
	signal.Notify(winch, syscall.SIGWINCH, syscall.SIGTERM, syscall.SIGHUP)

	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	focusTick := 0

	u.w, u.h, _ = term.GetSize(int(os.Stdout.Fd()))
	if u.w <= 0 {
		u.w, u.h = 26, 24
	}
	writeLensFocus(u.sess, !u.focus)
	u.draw()

	closedPath := filepath.Join(sess, "closed")
	rungPath := filepath.Join(sess, "rung")
	for {
		dirty := false
		select {
		case c, ok := <-keys:
			if !ok {
				return
			}
			switch c {
			case 'j', 'J':
				u.ctl("older")
			case 'k', 'K':
				u.ctl("newer")
			case 'a', 'A':
				cmd := exec.Command(u.ctlBin, "apply", u.sess)
				go func() { _ = cmd.Run() }()
			case 'q', 3, 27: // q, Ctrl-C, bare ESC
				return
			}
		case sig := <-winch:
			if sig != syscall.SIGWINCH {
				return
			}
			u.w, u.h, _ = term.GetSize(int(os.Stdout.Fd()))
			dirty = true
		case <-tick.C:
			if _, err := os.Stat(closedPath); err == nil {
				return
			}
			if n, err := strconv.Atoi(readTrim(rungPath)); err == nil && n != u.rungIdx {
				u.rungIdx = n
				dirty = true
			}
			focusTick++
			if focusTick%3 == 0 {
				if f := focused(); f != u.focus {
					u.focus = f
					dirty = true
					// Publish the LENS's focus (the negation of ours in a
					// two-pane tab) — pty-frame's --focus-file reads it to
					// dim/brighten the lens header.
					writeLensFocus(u.sess, !f)
				}
			}
		}
		if dirty {
			u.draw()
		}
	}
}

// writeLensFocus records whether the LENS pane holds the zellij focus —
// the lens chrome (pty-frame --focus-file) polls this to swap its header
// between the active and blurred palette, the same tiebreaker the explore
// lens gets from its in-yazi focus flag.
func writeLensFocus(sess string, lensFocused bool) {
	v := "0"
	if lensFocused {
		v = "1"
	}
	_ = os.WriteFile(filepath.Join(sess, "focus"), []byte(v), 0o644)
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
