//go:build windows

package main

import (
	"errors"
	"regexp"
	"syscall"
	"time"
	"unsafe"
)

// Буфер обмена Windows — для кнопки «Вставить» в полях окна. Читаем только по нажатию.
var (
	user32           = syscall.NewLazyDLL("user32.dll")
	kernel32         = syscall.NewLazyDLL("kernel32.dll")
	openClipboard    = user32.NewProc("OpenClipboard")
	closeClipboard   = user32.NewProc("CloseClipboard")
	getClipboardData = user32.NewProc("GetClipboardData")
	globalLock       = kernel32.NewProc("GlobalLock")
	globalUnlock     = kernel32.NewProc("GlobalUnlock")
)

const cfUnicodeText = 13

func readClipboard() (string, error) {
	// Сразу после «Копировать» Windows (журнал буфера, облачный буфер) держит буфер занятым
	// долю секунды — поэтому раньше «Вставить» срабатывала только со второго нажатия. Ждём до ~1 с.
	opened := false
	for i := 0; i < 20; i++ {
		if r, _, _ := openClipboard.Call(0); r != 0 {
			opened = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !opened {
		return "", errors.New("Буфер обмена занят. Попробуй ещё раз.")
	}
	defer closeClipboard.Call()
	h, _, _ := getClipboardData.Call(cfUnicodeText)
	if h == 0 {
		return "", nil
	}
	p, _, _ := globalLock.Call(h)
	if p == 0 {
		return "", nil
	}
	defer globalUnlock.Call(h)
	// Строка UTF-16 до нулевого символа, не длиннее 4096 знаков.
	buf := make([]uint16, 0, 256)
	for i := 0; i < 4096; i++ {
		c := *(*uint16)(unsafe.Pointer(p + uintptr(i)*2))
		if c == 0 {
			return syscall.UTF16ToString(buf), nil
		}
		buf = append(buf, c)
	}
	return "", nil
}

// Внешние ссылки из окна — только Telegram-чат по имени, страница Комбайна на GitHub и сайты хостеров из списка.
var linkOK = regexp.MustCompile(`^https://t\.me/[A-Za-z0-9_]{5,32}$|^https://github\.com/ln71v/kombain(/releases)?$|^https://(adminvps\.ru|fornex\.com|hip\.hosting|cloudvps\.by)$`)
