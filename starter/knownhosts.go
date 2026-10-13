package main

import (
	"encoding/json"
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
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(k.path), 0o700); err != nil {
		return nil // запомнили в памяти — до закрытия окна этого хватит
	}
	data, _ := json.MarshalIndent(m, "", " ")
	tmp := k.path + ".new"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, k.path)
	}
	return nil
}

// hostKeyErr — ключ сервера не подтверждён: пароль не отправлен.
type hostKeyErr struct {
	kind string // "newhost" — первый вход, "hostchanged" — ключ не совпал с запомненным
	fp   string
}

func (e *hostKeyErr) Error() string { return "host key not trusted: " + e.kind }
