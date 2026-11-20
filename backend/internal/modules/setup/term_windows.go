package setup

import (
	"os"
	"syscall"
	"unsafe"
)

const (
	enableProcessedInput = 0x1
	enableLineInput      = 0x2
	enableEchoInput      = 0x4
	enableVTInput        = 0x200
	enableVTProcessing   = 0x4
)

var (
	kernel32           = syscall.NewLazyDLL("kernel32.dll")
	procGetConsoleMode = kernel32.NewProc("GetConsoleMode")
	procSetConsoleMode = kernel32.NewProc("SetConsoleMode")
)

func getConsoleMode(f *os.File) (uint32, error) {
	var mode uint32
	if r, _, e := procGetConsoleMode.Call(f.Fd(), uintptr(unsafe.Pointer(&mode))); r == 0 {
		return 0, e
	}
	return mode, nil
}

func setConsoleMode(f *os.File, mode uint32) error {
	if r, _, e := procSetConsoleMode.Call(f.Fd(), uintptr(mode)); r == 0 {
		return e
	}
	return nil
}

func isTerminal(f *os.File) bool {
	_, err := getConsoleMode(f)
	return err == nil
}

// makeRaw makes the console send keys one by one, arrows as escape
// sequences, and lets out interpret ANSI sequences.
func makeRaw(in, out *os.File) (func(), error) {
	oldIn, err := getConsoleMode(in)
	if err != nil {
		return nil, err
	}
	oldOut, err := getConsoleMode(out)
	if err != nil {
		return nil, err
	}

	if err := setConsoleMode(out, oldOut|enableVTProcessing); err != nil {
		return nil, err
	}
	rawIn := oldIn&^(enableLineInput|enableEchoInput|enableProcessedInput) | enableVTInput
	if err := setConsoleMode(in, rawIn); err != nil {
		setConsoleMode(out, oldOut)
		return nil, err
	}
	return func() {
		setConsoleMode(in, oldIn)
		setConsoleMode(out, oldOut)
	}, nil
}

var procGetConsoleScreenBufferInfo = kernel32.NewProc("GetConsoleScreenBufferInfo")

type coord struct{ x, y int16 }

type smallRect struct{ left, top, right, bottom int16 }

type screenBufferInfo struct {
	size       coord
	cursor     coord
	attributes uint16
	window     smallRect
	maxSize    coord
}

func termSize(f *os.File) (cols, rows int) {
	var info screenBufferInfo
	if r, _, _ := procGetConsoleScreenBufferInfo.Call(f.Fd(), uintptr(unsafe.Pointer(&info))); r == 0 {
		return 0, 0
	}
	return int(info.window.right-info.window.left) + 1, int(info.window.bottom-info.window.top) + 1
}
