//go:build windows

package discord

import (
	"fmt"
	"io"
	"os"
)

func dial() (io.ReadWriteCloser, error) {
	var lastErr error
	for i := 0; i < 10; i++ {
		f, err := os.OpenFile(fmt.Sprintf(`\\.\pipe\discord-ipc-%d`, i), os.O_RDWR, 0)
		if err == nil {
			return f, nil
		}
		lastErr = err
	}
	return nil, lastErr
}
