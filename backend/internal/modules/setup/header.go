package setup

import (
	"bytes"
	_ "embed"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"strings"

	"nsonline/internal/version"
)

// logo.png is app/assets/icon_512.png cropped to the butterfly and sampled
// down to 16×16 (nearest neighbour), so it prints as 16 columns × 8 rows.
//
//go:embed logo.png
var logoPNG []byte

type colorMode int

const (
	noColor colorMode = iota
	color256
	trueColor
)

func detectColor(getenv func(string) string) colorMode {
	if getenv("NO_COLOR") != "" || getenv("TERM") == "dumb" {
		return noColor
	}
	switch strings.ToLower(getenv("COLORTERM")) {
	case "truecolor", "24bit":
		return trueColor
	}
	if getenv("WT_SESSION") != "" {
		return trueColor
	}
	return color256
}

func (m colorMode) style(code, s string) string {
	if m == noColor || s == "" {
		return s
	}
	return "\x1b[" + code + "m" + s + "\x1b[0m"
}

func (m colorMode) bold(s string) string { return m.style("1", s) }
func (m colorMode) dim(s string) string  { return m.style("2", s) }

func cubeLevel(v uint8) int {
	if v < 48 {
		return 0
	}
	if v < 115 {
		return 1
	}
	return (int(v) - 35) / 40
}

// to256 maps a colour to the nearest xterm-256 cube or grey ramp entry.
func to256(c color.NRGBA) int {
	levels := [6]int{0, 95, 135, 175, 215, 255}
	r, g, b := cubeLevel(c.R), cubeLevel(c.G), cubeLevel(c.B)
	cube := 16 + 36*r + 6*g + b
	dist := func(x, y, z int) int {
		dx, dy, dz := x-int(c.R), y-int(c.G), z-int(c.B)
		return dx*dx + dy*dy + dz*dz
	}

	avg := (int(c.R) + int(c.G) + int(c.B)) / 3
	grey := (avg - 3) / 10
	if grey < 0 {
		grey = 0
	}
	if grey > 23 {
		grey = 23
	}
	gv := 8 + 10*grey
	if dist(gv, gv, gv) < dist(levels[r], levels[g], levels[b]) {
		return 232 + grey
	}
	return cube
}

func (m colorMode) paint(c color.NRGBA, bg bool) string {
	base := 38
	if bg {
		base = 48
	}
	if m == trueColor {
		return fmt.Sprintf("%d;2;%d;%d;%d", base, c.R, c.G, c.B)
	}
	return fmt.Sprintf("%d;5;%d", base, to256(c))
}

func decodeLogo() (*image.NRGBA, error) {
	img, err := png.Decode(bytes.NewReader(logoPNG))
	if err != nil {
		return nil, err
	}
	b := img.Bounds()
	out := image.NewNRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	for y := 0; y < b.Dy(); y++ {
		for x := 0; x < b.Dx(); x++ {
			out.Set(x, y, img.At(b.Min.X+x, b.Min.Y+y))
		}
	}
	return out, nil
}

// logoLines draws two pixels per cell with half blocks. Transparent pixels
// stay the terminal background.
func logoLines(img *image.NRGBA, m colorMode) []string {
	b := img.Bounds()
	var lines []string
	for y := 0; y < b.Dy(); y += 2 {
		var sb strings.Builder
		for x := 0; x < b.Dx(); x++ {
			top := img.NRGBAAt(x, y)
			bot := color.NRGBA{}
			if y+1 < b.Dy() {
				bot = img.NRGBAAt(x, y+1)
			}
			switch {
			case top.A < 128 && bot.A < 128:
				sb.WriteString(" ")
			case bot.A < 128:
				sb.WriteString("\x1b[" + m.paint(top, false) + "m▀\x1b[0m")
			case top.A < 128:
				sb.WriteString("\x1b[" + m.paint(bot, false) + "m▄\x1b[0m")
			default:
				sb.WriteString("\x1b[" + m.paint(top, false) + ";" + m.paint(bot, true) + "m▀\x1b[0m")
			}
		}
		lines = append(lines, sb.String())
	}
	return lines
}

type header struct {
	title string
	sub   string
	help  string
}

func newHeader(title, sub, help string) header {
	return header{title: title, sub: sub, help: help}
}

func (h header) text(m colorMode) []string {
	text := []string{m.bold(h.title) + " " + m.dim("v"+version.Version)}
	if h.sub != "" {
		text = append(text, m.dim(h.sub))
	}
	if h.help != "" {
		text = append(text, m.dim(h.help))
	}
	return text
}

// lines puts the logo left of the text, unless colours are off or it
// wouldn't fit in cols (0 = unknown width).
func (h header) lines(m colorMode, cols int) []string {
	text := h.text(m)
	if m == noColor {
		return text
	}

	img, err := decodeLogo()
	if err != nil {
		return text
	}
	logo := logoLines(img, m)

	widest := 0
	for _, t := range text {
		widest = max(widest, visibleLen(t))
	}
	if cols > 0 && img.Bounds().Dx()+2+widest > cols {
		return text
	}

	top := (len(logo) - len(text)) / 2
	for i := range logo {
		if j := i - top; j >= 0 && j < len(text) {
			logo[i] += "  " + text[j]
		}
		logo[i] = strings.TrimRight(logo[i], " ")
	}
	return logo
}

func (h header) write(w io.Writer, m colorMode) {
	for _, l := range h.lines(m, 0) {
		fmt.Fprintln(w, l)
	}
}

func visibleLen(s string) int {
	n, esc := 0, false
	for _, r := range s {
		switch {
		case esc:
			esc = !(r >= '@' && r <= '~' && r != '[')
		case r == 0x1b:
			esc = true
		default:
			n++
		}
	}
	return n
}

// cut keeps the first n visible runes of s, escape sequences included.
func cut(s string, n int) string {
	if n <= 0 || visibleLen(s) <= n {
		return s
	}
	var sb strings.Builder
	count, esc := 0, false
	for _, r := range s {
		switch {
		case esc:
			esc = !(r >= '@' && r <= '~' && r != '[')
			sb.WriteRune(r)
			continue
		case r == 0x1b:
			esc = true
			sb.WriteRune(r)
			continue
		}
		if count == n {
			continue
		}
		sb.WriteRune(r)
		count++
	}
	return sb.String() + "\x1b[0m"
}
