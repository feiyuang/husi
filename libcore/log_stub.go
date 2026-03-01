//go:build !android

package libcore

func dup(oldFd, newFd, flags int) error {
	return nil
}
