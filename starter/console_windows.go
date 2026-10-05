//go:build windows

package main

import "golang.org/x/sys/windows"

// Русские буквы в окне Windows: включаем UTF-8.
func setupConsole() {
	_ = windows.SetConsoleOutputCP(65001)
	_ = windows.SetConsoleCP(65001)
}
