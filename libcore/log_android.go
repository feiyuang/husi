package libcore

import (
	"golang.org/x/sys/unix"
)

func dup(oldFd, newFd, flags int) error {
	return unix.Dup3(oldFd, newFd, flags)
}
