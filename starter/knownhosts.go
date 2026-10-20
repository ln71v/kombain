package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
)

// knownHosts — запомненные отпечатки серверов: адрес → SHA256 ключа.
// Пароль уходит на сервер только если его ключ совпал с запомненным
// или человек сам подтвердил новый ключ. Иначе подменённый сервер получил бы пароль root.
type knownHosts struct {
	mu   sync.Mutex
	path string            // "" — файла нет, помним только до закрытия окна
	mem  map[string]string // на случай, если файл записать не вышло
}

func newKnownHosts(path string) *knownHosts {
	return &knownHosts{path: path, mem: map[string]string{}}
}

// knownHostsPath — где лежит файл с отпечатками. Android подменяет его на папку приложения (SetDataDir).
var knownHostsPath = defaultKnownHostsPath

// defaultKnownHostsPath — %AppData%\Kombain\known_hosts.json на Windows.
func defaultKnownHostsPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "Kombain", "known_hosts.json")
}

func (k *knownHosts) load() map[string]string {
	m := map[string]string{}
	for h, fp := range k.mem {
		m[h] = fp
	}
	if k.path == "" {
		return m
	}
	data, err := os.ReadFile(k.path)
	if err != nil {
		return m
	}
	var disk map[string]string
	if json.Unmarshal(data, &disk) == nil {
		for h, fp := range disk {
			if _, ok := m[h]; !ok {
				m[h] = fp
			}
		}
	}
	return m
}

func (k *knownHosts) get(host string) string {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.load()[host]
}

func (k *knownHosts) set(host, fp string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	m := k.load()
	m[host] = fp
	k.mem[host] = fp
	if k.path == "" {
		return errNotSaved
	}
	if err := os.MkdirAll(filepath.Dir(k.path), 0o700); err != nil {
		return errNotSaved
	}
	data, _ := json.MarshalIndent(m, "", " ")
	tmp := k.path + ".new"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return errNotSaved
	}
	if err := os.Rename(tmp, k.path); err != nil {
		_ = os.Remove(tmp)
		return errNotSaved
	}
	return nil
}

// errNotSaved — в памяти запомнили (в этом окне войти можно), а в файл не записалось:
// после перезапуска установщик спросит про этот сервер снова.
var errNotSaved = errors.New("Сервер принят, но только до закрытия окна: не смогла записать файл с отпечатками. " +
	"Введи пароль и жми «Войти». В следующий раз спрошу про этот сервер снова.")

// hostKeyErr — ключ сервера не подтверждён: пароль не отправлен.
type hostKeyErr struct {
	kind string // "newhost" — первый вход, "hostchanged" — ключ не совпал с запомненным
	fp   string
}

func (e *hostKeyErr) Error() string { return "host key not trusted: " + e.kind }
