// pty-frame — draw a titled box and run a child TUI inside it.
//
// The child (typically fzf) runs in a *sub-pty* sized to the inner content
// area, narrower/shorter than the real pane. Because the child's terminal is
// the sub-pty, its full-width clears can't touch the cells outside it — so the
// frame we draw (outer border + a "▓▓▓ <title>" header + rule) survives on
// every row. We emulate the child's output into a colored cell grid and blit it
// into the frame each frame, forward keystrokes to it, and relay its stdout
// (the selection) verbatim. See README.md for the why.
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"github.com/mattn/go-runewidth"
	"golang.org/x/term"
)

// ----------------------------------------------------------------------------
// colors
// ----------------------------------------------------------------------------

type color struct {
	set     bool
	r, g, b uint8
}

func parseHex(s string) color {
	s = strings.TrimPrefix(strings.TrimSpace(s), "#")
	if len(s) != 6 {
		return color{}
	}
	v, err := strconv.ParseUint(s, 16, 32)
	if err != nil {
		return color{}
	}
	return color{set: true, r: uint8(v >> 16), g: uint8(v >> 8), b: uint8(v)}
}

func (c color) fgSGR() string {
	if !c.set {
		return "39"
	}
	return fmt.Sprintf("38;2;%d;%d;%d", c.r, c.g, c.b)
}

func (c color) bgSGR(fallback color) string {
	use := c
	if !c.set {
		use = fallback
	}
	if !use.set {
		return "49"
	}
	return fmt.Sprintf("48;2;%d;%d;%d", use.r, use.g, use.b)
}

// xterm 256-color → RGB (16 base, 216 cube, 24 gray).
var base16 = [16][3]uint8{
	{0, 0, 0}, {205, 0, 0}, {0, 205, 0}, {205, 205, 0},
	{0, 0, 238}, {205, 0, 205}, {0, 205, 205}, {229, 229, 229},
	{127, 127, 127}, {255, 0, 0}, {0, 255, 0}, {255, 255, 0},
	{92, 92, 255}, {255, 0, 255}, {0, 255, 255}, {255, 255, 255},
}

func xterm256(n int) color {
	switch {
	case n < 16:
		return color{true, base16[n][0], base16[n][1], base16[n][2]}
	case n < 232:
		n -= 16
		conv := func(v int) uint8 {
			if v == 0 {
				return 0
			}
			return uint8(55 + v*40)
		}
		return color{true, conv(n / 36 % 6), conv(n / 6 % 6), conv(n % 6)}
	default:
		g := uint8(8 + (n-232)*10)
		return color{true, g, g, g}
	}
}

// ----------------------------------------------------------------------------
// cell grid + minimal VT emulator
// ----------------------------------------------------------------------------

const (
	attrBold    = 1 << 0
	attrDim     = 1 << 1
	attrReverse = 1 << 2
)

type cell struct {
	r     rune
	fg    color
	bg    color
	attrs uint8
}

type grid struct {
	w, h          int
	cells         [][]cell
	curX, curY    int
	penFg, penBg  color
	penAttrs      uint8
	cursorVisible bool
	cprRequested  bool

	// parser state
	pending []byte // incomplete trailing bytes carried across feeds
	state   int
	params  []byte
	inter   []byte
}

const (
	stGround = iota
	stEsc
	stCSI
	stOSC
)

func newGrid(w, h int) *grid {
	g := &grid{w: w, h: h, cursorVisible: true}
	g.alloc()
	return g
}

func (g *grid) alloc() {
	g.cells = make([][]cell, g.h)
	for y := range g.cells {
		g.cells[y] = make([]cell, g.w)
		for x := range g.cells[y] {
			g.cells[y][x] = cell{r: ' '}
		}
	}
	if g.curX >= g.w {
		g.curX = g.w - 1
	}
	if g.curY >= g.h {
		g.curY = g.h - 1
	}
}

func (g *grid) resize(w, h int) {
	g.w, g.h = w, h
	g.curX, g.curY = 0, 0
	g.alloc()
}

func (g *grid) clearRegion(x0, y0, x1, y1 int) {
	blank := cell{r: ' ', bg: g.penBg}
	for y := y0; y <= y1 && y < g.h; y++ {
		if y < 0 {
			continue
		}
		for x := x0; x <= x1 && x < g.w; x++ {
			if x < 0 {
				continue
			}
			g.cells[y][x] = blank
		}
	}
}

func (g *grid) put(r rune) {
	if g.curY < 0 || g.curY >= g.h {
		return
	}
	w := runewidth.RuneWidth(r)
	if w == 0 {
		return // combining/zero-width: drop (good enough for fzf)
	}
	if g.curX >= g.w {
		g.curX = g.w - 1 // autowrap off: clamp
	}
	g.cells[g.curY][g.curX] = cell{r: r, fg: g.penFg, bg: g.penBg, attrs: g.penAttrs}
	for i := 1; i < w && g.curX+i < g.w; i++ {
		g.cells[g.curY][g.curX+i] = cell{r: 0, fg: g.penFg, bg: g.penBg, attrs: g.penAttrs} // wide-char trailer
	}
	g.curX += w
}

func (g *grid) feed(data []byte) {
	buf := append(g.pending, data...)
	g.pending = nil
	i := 0
	for i < len(buf) {
		b := buf[i]
		switch g.state {
		case stGround:
			switch {
			case b == 0x1b:
				g.state = stEsc
				i++
			case b == '\r':
				g.curX = 0
				i++
			case b == '\n':
				if g.curY < g.h-1 {
					g.curY++
				}
				i++
			case b == '\b':
				if g.curX > 0 {
					g.curX--
				}
				i++
			case b == '\t':
				g.curX = (g.curX/8 + 1) * 8
				if g.curX >= g.w {
					g.curX = g.w - 1
				}
				i++
			case b < 0x20:
				i++ // drop other control bytes
			default:
				r, size := decodeRune(buf[i:])
				if r == rerrIncomplete {
					g.pending = append(g.pending, buf[i:]...)
					return
				}
				g.put(r)
				i += size
			}
		case stEsc:
			switch b {
			case '[':
				g.state = stCSI
				g.params = g.params[:0]
				g.inter = g.inter[:0]
			case ']':
				g.state = stOSC
			case '(', ')', '*', '+':
				i++ // charset designator: skip the next byte too
				g.state = stGround
			default:
				g.state = stGround
			}
			i++
		case stCSI:
			switch {
			case b >= 0x30 && b <= 0x3f: // params (digits, ;, ?, etc.)
				g.params = append(g.params, b)
			case b >= 0x20 && b <= 0x2f: // intermediates
				g.inter = append(g.inter, b)
			case b >= 0x40 && b <= 0x7e: // final byte
				g.dispatchCSI(b)
				g.state = stGround
			}
			i++
		case stOSC:
			// skip until BEL or ST (ESC \)
			if b == 0x07 {
				g.state = stGround
			} else if b == 0x1b {
				// peek for backslash
				if i+1 < len(buf) && buf[i+1] == '\\' {
					i++
				}
				g.state = stGround
			}
			i++
		}
	}
}

func (g *grid) csiParams() []int {
	s := string(g.params)
	if strings.HasPrefix(s, "?") {
		s = s[1:]
	}
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ";")
	out := make([]int, len(parts))
	for i, p := range parts {
		// fzf truecolor uses ';'; tolerate ':' inside a single param too
		p = strings.ReplaceAll(p, ":", ";")
		if p == "" {
			out[i] = 0
			continue
		}
		// only the leading integer matters for our handlers
		n, _ := strconv.Atoi(strings.SplitN(p, ";", 2)[0])
		out[i] = n
	}
	return out
}

func (g *grid) dispatchCSI(final byte) {
	private := strings.HasPrefix(string(g.params), "?")
	p := g.csiParams()
	arg := func(i, def int) int {
		if i < len(p) && p[i] != 0 {
			return p[i]
		}
		if i < len(p) {
			return p[i]
		}
		return def
	}
	switch final {
	case 'H', 'f': // CUP
		row := arg(0, 1)
		col := arg(1, 1)
		g.curY = clamp(row-1, 0, g.h-1)
		g.curX = clamp(col-1, 0, g.w-1)
	case 'A':
		g.curY = clamp(g.curY-max1(arg(0, 1)), 0, g.h-1)
	case 'B':
		g.curY = clamp(g.curY+max1(arg(0, 1)), 0, g.h-1)
	case 'C':
		g.curX = clamp(g.curX+max1(arg(0, 1)), 0, g.w-1)
	case 'D':
		g.curX = clamp(g.curX-max1(arg(0, 1)), 0, g.w-1)
	case 'G': // CHA
		g.curX = clamp(arg(0, 1)-1, 0, g.w-1)
	case 'd': // VPA
		g.curY = clamp(arg(0, 1)-1, 0, g.h-1)
	case 'J': // ED
		switch arg(0, 0) {
		case 0:
			g.clearRegion(g.curX, g.curY, g.w-1, g.curY)
			g.clearRegion(0, g.curY+1, g.w-1, g.h-1)
		case 1:
			g.clearRegion(0, 0, g.w-1, g.curY-1)
			g.clearRegion(0, g.curY, g.curX, g.curY)
		case 2, 3:
			g.clearRegion(0, 0, g.w-1, g.h-1)
		}
	case 'K': // EL
		switch arg(0, 0) {
		case 0:
			g.clearRegion(g.curX, g.curY, g.w-1, g.curY)
		case 1:
			g.clearRegion(0, g.curY, g.curX, g.curY)
		case 2:
			g.clearRegion(0, g.curY, g.w-1, g.curY)
		}
	case 'm': // SGR
		g.applySGR(p)
	case 'n': // DSR
		if !private && arg(0, 0) == 6 {
			g.cprRequested = true
		}
	case 'h', 'l':
		if private && arg(0, 0) == 25 {
			g.cursorVisible = final == 'h'
		}
		if private {
			switch arg(0, 0) {
			case 1049, 47, 1047: // alt screen: treat enter/leave as a clear
				g.clearRegion(0, 0, g.w-1, g.h-1)
				g.curX, g.curY = 0, 0
			}
		}
	}
}

func (g *grid) applySGR(p []int) {
	if len(p) == 0 {
		p = []int{0}
	}
	for i := 0; i < len(p); i++ {
		n := p[i]
		switch {
		case n == 0:
			g.penFg, g.penBg, g.penAttrs = color{}, color{}, 0
		case n == 1:
			g.penAttrs |= attrBold
		case n == 2:
			g.penAttrs |= attrDim
		case n == 22:
			g.penAttrs &^= attrBold | attrDim
		case n == 7:
			g.penAttrs |= attrReverse
		case n == 27:
			g.penAttrs &^= attrReverse
		case n >= 30 && n <= 37:
			g.penFg = xterm256(n - 30)
		case n == 39:
			g.penFg = color{}
		case n >= 40 && n <= 47:
			g.penBg = xterm256(n - 40)
		case n == 49:
			g.penBg = color{}
		case n >= 90 && n <= 97:
			g.penFg = xterm256(n - 90 + 8)
		case n >= 100 && n <= 107:
			g.penBg = xterm256(n - 100 + 8)
		case n == 38 || n == 48:
			c, adv := readExtColor(p, i)
			if n == 38 {
				g.penFg = c
			} else {
				g.penBg = c
			}
			i += adv
		}
	}
}

// readExtColor parses 38;2;r;g;b or 38;5;n starting at p[i] (the 38/48). Returns
// the color and how many extra params it consumed.
func readExtColor(p []int, i int) (color, int) {
	if i+1 >= len(p) {
		return color{}, 0
	}
	switch p[i+1] {
	case 2:
		if i+4 < len(p) {
			return color{true, uint8(p[i+2]), uint8(p[i+3]), uint8(p[i+4])}, 4
		}
		return color{}, len(p) - i - 1
	case 5:
		if i+2 < len(p) {
			return xterm256(p[i+2]), 2
		}
		return color{}, len(p) - i - 1
	}
	return color{}, 1
}

// ----------------------------------------------------------------------------
// rune decoding with incomplete-tail detection
// ----------------------------------------------------------------------------

const rerrIncomplete = rune(-1)

func decodeRune(b []byte) (rune, int) {
	if len(b) == 0 {
		return rerrIncomplete, 0
	}
	c := b[0]
	var need int
	switch {
	case c < 0x80:
		return rune(c), 1
	case c&0xe0 == 0xc0:
		need = 2
	case c&0xf0 == 0xe0:
		need = 3
	case c&0xf8 == 0xf0:
		need = 4
	default:
		return rune(c), 1 // invalid lead: pass through as latin1-ish
	}
	if len(b) < need {
		return rerrIncomplete, 0
	}
	r := rune(c & (0x7f >> need))
	for i := 1; i < need; i++ {
		if b[i]&0xc0 != 0x80 {
			return rune(c), 1
		}
		r = r<<6 | rune(b[i]&0x3f)
	}
	return r, need
}

// ----------------------------------------------------------------------------
// helpers
// ----------------------------------------------------------------------------

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func max1(n int) int {
	if n < 1 {
		return 1
	}
	return n
}

func setSize(f *os.File, w, h int) {
	_ = pty.Setsize(f, &pty.Winsize{Rows: uint16(h), Cols: uint16(w)})
}

// ----------------------------------------------------------------------------
// app
// ----------------------------------------------------------------------------

type config struct {
	title, hints                          string
	titleFile, focusFile                  string
	bg, fg, border, titleColor, ruleColor color
	titleColorBlur                        color
	bare, tui                             bool
	child                                 []string
}

// headerPad is the extra leading/trailing inset of the ▓▓▓ title + rule, on top
// of the 1-cell mantle gutter, so the header isn't flush against the box gutter.
const headerPad = 2

type app struct {
	cfg            config
	tty            *os.File
	g              *grid
	paneW, paneH   int // full pane size
	rowOff, colOff int // 1-based top-left of the sub-pty region in the real pane
	hintRow        int // 1-based row for the footer hints (0 = none)
	ptmx           *os.File
	mu             sync.Mutex
	focused        bool // --focus-file state; true = active chrome colors
}

func main() {
	cfg := parseArgs(os.Args[1:])
	if len(cfg.child) == 0 {
		fmt.Fprintln(os.Stderr, "pty-frame: missing child command (expected '-- CMD ...')")
		os.Exit(2)
	}

	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		fmt.Fprintln(os.Stderr, "pty-frame: cannot open /dev/tty:", err)
		os.Exit(2)
	}
	defer tty.Close()

	w, h, err := term.GetSize(int(tty.Fd()))
	if err != nil || w < 10 || h < 8 {
		fmt.Fprintln(os.Stderr, "pty-frame: cannot get usable tty size:", err)
		os.Exit(2)
	}

	a := &app{cfg: cfg, tty: tty, focused: true}
	a.refreshDynamic()
	a.layout(w, h)

	// Raw mode on the real tty so keystrokes pass straight through to the child.
	oldState, err := term.MakeRaw(int(tty.Fd()))
	if err != nil {
		fmt.Fprintln(os.Stderr, "pty-frame: cannot set raw mode:", err)
		os.Exit(2)
	}
	a.tty.WriteString("\x1b[?7l") // disable autowrap so full-width rows / the bottom-right corner don't scroll
	restore := func() {
		a.tty.WriteString("\x1b[?7h\x1b[?25h\x1b[0m") // autowrap on, show cursor, reset SGR
		term.Restore(int(tty.Fd()), oldState)
	}

	code, err := a.run()
	restore()
	if err != nil {
		fmt.Fprintln(os.Stderr, "pty-frame:", err)
	}
	os.Exit(code)
}

func (a *app) layout(w, h int) {
	if a.cfg.bare {
		// Bare (lens) mode: no box at all — title on row 1, rule on row 2,
		// the child owns everything below at full pane width. This is the
		// explore-lens header look, not the picker dialog.
		a.hintRow = 0
		innerH := h - 2
		if innerH < 1 {
			innerH = 1
		}
		a.paneW, a.paneH = w, h
		a.rowOff = 3
		a.colOff = 1
		if a.g == nil {
			a.g = newGrid(w, innerH)
		} else {
			a.g.resize(w, innerH)
		}
		return
	}
	// Frame, top→bottom: row1 top border(+label), row2 blank, row3 ▓▓▓ title,
	// row4 rule, then the child, then (when hints are set) a blank + the hints,
	// then the bottom border. Sides at col1/colW with a 1-cell mantle gutter, so
	// the child occupies cols 3..w-2.
	const topRows = 4 // border, blank, title, rule
	botRows := 1      // bottom border
	a.hintRow = 0
	if a.cfg.hints != "" {
		a.hintRow = h - 1 // blank on h-2, hints on h-1, border on h
		botRows = 3
	}
	innerW := w - 4
	innerH := h - topRows - botRows
	if innerW < 1 {
		innerW = 1
	}
	if innerH < 1 {
		innerH = 1
	}
	a.paneW, a.paneH = w, h
	a.rowOff = 5
	a.colOff = 3
	if a.g == nil {
		a.g = newGrid(innerW, innerH)
	} else {
		a.g.resize(innerW, innerH)
	}
}

func (a *app) run() (int, error) {
	// Sub-pty sized to the inner region.
	ptmx, pts, err := pty.Open()
	if err != nil {
		return 2, fmt.Errorf("openpty: %w", err)
	}
	defer ptmx.Close()
	setSize(ptmx, a.g.w, a.g.h)
	a.ptmx = ptmx

	// Selection + stderr pipes so the child's stdout (the result) stays
	// separate from its UI (which goes to the pty).
	selR, selW, _ := os.Pipe()
	errR, errW, _ := os.Pipe()

	cmd := exec.Command(a.cfg.child[0], a.cfg.child[1:]...)
	// Export the sub-pty's exact size to the child (fzf) + its --bind commands
	// (reload/preview), so pickers that size their layout to the pane (e.g.
	// pick-clipboard's item-line width) can read PTY_FRAME_COLUMNS/LINES
	// instead of guessing from tput cols. fzf sets FZF_PREVIEW_* for the
	// preview command but FZF_COLUMNS=0 for start:reload, so this is the
	// reliable source for the list-pane width.
	cmd.Env = append(os.Environ(),
		fmt.Sprintf("PTY_FRAME_COLUMNS=%d", a.g.w),
		fmt.Sprintf("PTY_FRAME_LINES=%d", a.g.h),
	)
	cmd.Stdin = os.Stdin // the list to filter
	if a.cfg.tui {
		// Full-TUI child (diffnav): our stdin is the pane's real tty, and
		// a tty-stdin would make the child read keys DIRECTLY, racing our
		// own forwarder. /dev/null forces it onto /dev/tty = the sub-pty.
		if devnull, err := os.Open(os.DevNull); err == nil {
			cmd.Stdin = devnull
			defer devnull.Close()
		}
	}
	cmd.Stdout = selW // the selection
	cmd.Stderr = errW
	cmd.ExtraFiles = []*os.File{pts} // child fd 3 = controlling tty
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 3}

	if err := cmd.Start(); err != nil {
		return 2, fmt.Errorf("start child: %w", err)
	}
	pts.Close()
	selW.Close()
	errW.Close()

	var selBuf, errBuf bytes.Buffer
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); io.Copy(&selBuf, selR) }()
	go func() { defer wg.Done(); io.Copy(&errBuf, errR) }()

	// Forward keystrokes: real tty → child pty (daemon; dies with the process).
	go io.Copy(ptmx, a.tty)

	// Resize: redraw chrome + resize the sub-pty on SIGWINCH.
	winch := make(chan os.Signal, 1)
	signal.Notify(winch, syscall.SIGWINCH)
	defer signal.Stop(winch)
	go func() {
		for range winch {
			if w, h, err := term.GetSize(int(a.tty.Fd())); err == nil && w >= 10 && h >= 8 {
				a.mu.Lock()
				a.layout(w, h)
				setSize(a.ptmx, a.g.w, a.g.h)
				a.drawChrome()
				a.blit()
				a.mu.Unlock()
			}
		}
	}()

	a.mu.Lock()
	a.drawChrome()
	a.blit()
	a.mu.Unlock()

	// Dynamic chrome: poll the title/focus files and repaint on change
	// (daemon goroutine; dies with the process, like the key forwarder).
	if a.cfg.titleFile != "" || a.cfg.focusFile != "" {
		go func() {
			t := time.NewTicker(300 * time.Millisecond)
			defer t.Stop()
			for range t.C {
				a.mu.Lock()
				if a.refreshDynamic() {
					a.drawChrome()
					a.blit()
				}
				a.mu.Unlock()
			}
		}()
	}

	// Pump the child UI → emulator → blit until the pty closes (child exits).
	buf := make([]byte, 32*1024)
	for {
		n, err := ptmx.Read(buf)
		if n > 0 {
			a.mu.Lock()
			a.g.feed(buf[:n])
			if a.g.cprRequested {
				a.g.cprRequested = false
				fmt.Fprintf(ptmx, "\x1b[%d;%dR", a.g.curY+1, a.g.curX+1)
			}
			a.blit()
			a.mu.Unlock()
		}
		if err != nil {
			break
		}
	}

	cmd.Wait()
	wg.Wait()
	os.Stdout.Write(selBuf.Bytes())

	code := 0
	if cmd.ProcessState != nil {
		code = cmd.ProcessState.ExitCode()
	}
	if code != 0 && errBuf.Len() > 0 {
		fmt.Fprint(os.Stderr, errBuf.String())
	}
	return code, nil
}

// ----------------------------------------------------------------------------
// rendering
// ----------------------------------------------------------------------------

func (a *app) drawChrome() {
	w, h := a.paneW, a.paneH
	var b strings.Builder
	if a.cfg.bare {
		// Bare (lens) mode: repaint ONLY the two header rows — no flood
		// (the child owns everything from rowOff down and a 2J here would
		// blank it between chrome and blit).
		b.WriteString("\x1b[?2026h")
		bg := a.cfg.bg.bgSGR(color{})
		moveTo(&b, 1, 1)
		b.WriteString("\x1b[" + bg + "m\x1b[2K")
		b.WriteString("\x1b[" + bg + ";" + a.effTitleColor().fgSGR() + "m " + a.cfg.title)
		moveTo(&b, 2, 1)
		b.WriteString("\x1b[" + bg + "m\x1b[2K")
		ruleW := w - 2
		if ruleW < 1 {
			ruleW = 1
		}
		moveTo(&b, 2, 2)
		b.WriteString("\x1b[" + bg + ";" + a.cfg.ruleColor.fgSGR() + "m" + strings.Repeat("━", ruleW))
		b.WriteString("\x1b[0m\x1b[?2026l")
		a.tty.WriteString(b.String())
		return
	}
	b.WriteString("\x1b[?2026h")
	bg := a.cfg.bg.bgSGR(color{})
	// flood the whole pane with the dialog bg
	b.WriteString("\x1b[" + bg + "m\x1b[2J")
	border := a.cfg.border.fgSGR()

	top := "╭" + strings.Repeat("─", w-2) + "╮"
	moveTo(&b, 1, 1)
	b.WriteString("\x1b[" + bg + ";" + border + "m" + top)

	for row := 2; row <= h-1; row++ {
		moveTo(&b, row, 1)
		b.WriteString("\x1b[" + bg + ";" + border + "m│")
		moveTo(&b, row, w)
		b.WriteString("\x1b[" + bg + ";" + border + "m│")
	}
	moveTo(&b, h, 1)
	b.WriteString("\x1b[" + bg + ";" + border + "m╰" + strings.Repeat("─", w-2) + "╯")

	// Header block: row 3 "▓▓▓ <title>", row 4 the rule, inset by headerPad on
	// each side so they aren't flush against the gutter.
	if a.cfg.title != "" {
		moveTo(&b, 3, a.colOff+headerPad)
		b.WriteString("\x1b[" + bg + ";" + a.effTitleColor().fgSGR() + "m▓▓▓ " + a.cfg.title)
		ruleW := a.g.w - 2*headerPad
		if ruleW < 1 {
			ruleW = 1
		}
		moveTo(&b, 4, a.colOff+headerPad)
		b.WriteString("\x1b[" + bg + ";" + a.cfg.ruleColor.fgSGR() + "m" + strings.Repeat("━", ruleW))
	}

	// Footer hints (pre-colored by the caller; we own only the position + bg).
	// Aligned with the header's inset so the title and hints share a left edge.
	if a.cfg.hints != "" && a.hintRow > 0 {
		moveTo(&b, a.hintRow, a.colOff+headerPad)
		b.WriteString("\x1b[" + bg + "m" + a.cfg.hints)
	}

	b.WriteString("\x1b[0m\x1b[?2026l")
	a.tty.WriteString(b.String())
}

func (a *app) blit() {
	var b strings.Builder
	b.WriteString("\x1b[?2026h\x1b[?25l")
	for y := 0; y < a.g.h; y++ {
		moveTo(&b, a.rowOff+y, a.colOff)
		prev := ""
		for x := 0; x < a.g.w; x++ {
			c := a.g.cells[y][x]
			if c.r == 0 {
				continue // wide-char trailer cell
			}
			fg, bg := c.fg, c.bg
			if c.attrs&attrReverse != 0 {
				rf := fg
				if !rf.set {
					rf = a.cfg.fg
				}
				rb := bg
				if !rb.set {
					rb = a.cfg.bg
				}
				fg, bg = rb, rf
			}
			sgr := "\x1b[0"
			if c.attrs&attrBold != 0 {
				sgr += ";1"
			}
			if c.attrs&attrDim != 0 {
				sgr += ";2"
			}
			sgr += ";" + bg.bgSGR(a.cfg.bg) + ";" + fg.fgSGR() + "m"
			if sgr != prev {
				b.WriteString(sgr)
				prev = sgr
			}
			r := c.r
			if r < 0x20 {
				r = ' '
			}
			b.WriteRune(r)
		}
		b.WriteString("\x1b[0m")
	}
	moveTo(&b, a.rowOff+a.g.curY, a.colOff+a.g.curX)
	if a.g.cursorVisible {
		b.WriteString("\x1b[?25h")
	}
	b.WriteString("\x1b[?2026l")
	a.tty.WriteString(b.String())
}

func moveTo(b *strings.Builder, row, col int) {
	b.WriteString("\x1b[")
	b.WriteString(strconv.Itoa(row))
	b.WriteByte(';')
	b.WriteString(strconv.Itoa(col))
	b.WriteByte('H')
}

// ----------------------------------------------------------------------------
// args
// ----------------------------------------------------------------------------

func parseArgs(args []string) config {
	cfg := config{}
	i := 0
	val := func() string {
		i++
		if i < len(args) {
			return args[i]
		}
		return ""
	}
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--":
			cfg.child = append([]string{}, args[i+1:]...)
			return cfg
		case a == "--title":
			cfg.title = val()
		case strings.HasPrefix(a, "--title="):
			cfg.title = a[len("--title="):]
		case a == "--hints":
			cfg.hints = val()
		case strings.HasPrefix(a, "--hints="):
			cfg.hints = a[len("--hints="):]
		case a == "--bg":
			cfg.bg = parseHex(val())
		case strings.HasPrefix(a, "--bg="):
			cfg.bg = parseHex(a[len("--bg="):])
		case a == "--fg":
			cfg.fg = parseHex(val())
		case strings.HasPrefix(a, "--fg="):
			cfg.fg = parseHex(a[len("--fg="):])
		case a == "--border-color":
			cfg.border = parseHex(val())
		case strings.HasPrefix(a, "--border-color="):
			cfg.border = parseHex(a[len("--border-color="):])
		case a == "--title-color":
			cfg.titleColor = parseHex(val())
		case strings.HasPrefix(a, "--title-color="):
			cfg.titleColor = parseHex(a[len("--title-color="):])
		case a == "--rule-color":
			cfg.ruleColor = parseHex(val())
		case strings.HasPrefix(a, "--rule-color="):
			cfg.ruleColor = parseHex(a[len("--rule-color="):])
		case a == "--title-color-blur":
			cfg.titleColorBlur = parseHex(val())
		case strings.HasPrefix(a, "--title-color-blur="):
			cfg.titleColorBlur = parseHex(a[len("--title-color-blur="):])
		case a == "--title-file":
			cfg.titleFile = val()
		case strings.HasPrefix(a, "--title-file="):
			cfg.titleFile = a[len("--title-file="):]
		case a == "--focus-file":
			cfg.focusFile = val()
		case strings.HasPrefix(a, "--focus-file="):
			cfg.focusFile = a[len("--focus-file="):]
		case a == "--bare":
			cfg.bare = true
		case a == "--tui":
			cfg.tui = true
		}
		i++
	}
	return cfg
}

// refreshDynamic re-reads the --title-file / --focus-file channels and
// reports whether the chrome needs a redraw. Missing files keep the last
// state (focus defaults to true so a bare title starts active).
func (a *app) refreshDynamic() bool {
	changed := false
	if a.cfg.titleFile != "" {
		if b, err := os.ReadFile(a.cfg.titleFile); err == nil {
			t := strings.TrimSpace(string(b))
			if t != "" && t != a.cfg.title {
				a.cfg.title = t
				changed = true
			}
		}
	}
	if a.cfg.focusFile != "" {
		f := true
		if b, err := os.ReadFile(a.cfg.focusFile); err == nil {
			f = strings.TrimSpace(string(b)) != "0"
		}
		if f != a.focused {
			a.focused = f
			changed = true
		}
	}
	return changed
}

// effTitleColor is the focus-aware title color: the blur variant applies
// whenever a focus channel says the pane lost focus (and a blur color was
// given); everything else keeps the active color.
func (a *app) effTitleColor() color {
	if !a.focused && a.cfg.titleColorBlur.set {
		return a.cfg.titleColorBlur
	}
	return a.cfg.titleColor
}
