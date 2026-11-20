//go:build darwin || freebsd || netbsd || openbsd || dragonfly

package setup

import "syscall"

const (
	ioctlGet = syscall.TIOCGETA
	ioctlSet = syscall.TIOCSETA
)
