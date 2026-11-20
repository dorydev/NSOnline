//go:build darwin || linux || freebsd || netbsd || openbsd || dragonfly

package setup

import (
	"os"
	"syscall"
	"unsafe"
)

func getTermios(fd uintptr) (*syscall.Termios, error) {
	var t syscall.Termios
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, ioctlGet, uintptr(unsafe.Pointer(&t))); e != 0 {
		return nil, e
	}
	return &t, nil
}

func setTermios(fd uintptr, t *syscall.Termios) error {
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, ioctlSet, uintptr(unsafe.Pointer(t))); e != 0 {
		return e
	}
	return nil
}

func isTerminal(f *os.File) bool {
	_, err := getTermios(f.Fd())
	return err == nil
}

func makeRaw(in, out *os.File) (func(), error) {
	fd := in.Fd()
	old, err := getTermios(fd)
	if err != nil {
		return nil, err
	}

	raw := *old
	raw.Lflag &^= syscall.ICANON | syscall.ECHO | syscall.ISIG | syscall.IEXTEN
	raw.Iflag &^= syscall.ICRNL | syscall.IXON
	raw.Cc[syscall.VMIN] = 1
	raw.Cc[syscall.VTIME] = 0
	if err := setTermios(fd, &raw); err != nil {
		return nil, err
	}
	return func() { setTermios(fd, old) }, nil
}

type winsize struct{ row, col, x, y uint16 }

func termSize(f *os.File) (cols, rows int) {
	var ws winsize
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), syscall.TIOCGWINSZ, uintptr(unsafe.Pointer(&ws))); e != 0 {
		return 0, 0
	}
	return int(ws.col), int(ws.row)
}
