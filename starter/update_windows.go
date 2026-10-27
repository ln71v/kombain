//go:build windows

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Обновление kombain-start.exe по кнопке «Обновить».
// Сверяем сумму своего файла с kombain-start.exe.sha256 последнего релиза. Не совпала — есть новая версия.
// Обновление: скачать, сверить сумму, старый файл переименовать в *.old, новый положить на его место,
// запустить новый и закрыть окно. *.old удаляется при следующем запуске.
const (
	updBase   = "https://github.com/ln71v/kombain/releases/latest/download/"
	updExe    = "kombain-start.exe"
	updMaxExe = 60 << 20
)

var sumPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type exeUpdater struct {
	mu        sync.Mutex
	remoteSum string
}

// Только https и только GitHub — сами проверяем каждое перенаправление.
var updClient = &http.Client{
	Timeout: 3 * time.Minute,
	CheckRedirect: func(r *http.Request, via []*http.Request) error {
		if len(via) > 5 || !allowedHost(r.URL) {
			return errors.New("bad redirect")
		}
		return nil
	},
}

func allowedHost(u *url.URL) bool {
	h := u.Hostname()
	return u.Scheme == "https" && (h == "github.com" || strings.HasSuffix(h, ".githubusercontent.com"))
}

func fetch(name string, limit int64, w io.Writer) error {
	r, err := updClient.Get(updBase + name)
	if err != nil {
		return err
	}
	defer r.Body.Close()
	if r.StatusCode != http.StatusOK {
		return fmt.Errorf("http %d", r.StatusCode)
	}
	n, err := io.Copy(w, io.LimitReader(r.Body, limit+1))
	if err == nil && n > limit {
		err = errors.New("too big")
	}
	return err
}

func fileSum(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// check — true, если на GitHub лежит другая (новая) сборка. Без интернета — просто false.
func (u *exeUpdater) check() (bool, error) {
	if strings.Contains(version, "dev") {
		return false, nil // тестовые сборки не обновляем
	}
	var b strings.Builder
	if err := fetch(updExe+".sha256", 4096, &b); err != nil {
		return false, nil
	}
	f := strings.Fields(b.String())
	if len(f) == 0 || !sumPattern.MatchString(strings.ToLower(f[0])) {
		return false, nil
	}
	remote := strings.ToLower(f[0])
	me, err := os.Executable()
	if err != nil {
		return false, nil
	}
	mine, err := fileSum(me)
	if err != nil {
		return false, nil
	}
	u.mu.Lock()
	u.remoteSum = remote
	u.mu.Unlock()
	return remote != mine, nil
}

// install — скачать, проверить и подменить себя. После успеха окно закрывается само.
func (u *exeUpdater) install(restart func()) error {
	fail := errors.New("Не получилось обновиться само. Скачай новую версию со страницы Комбайна — кнопка ниже.")
	u.mu.Lock()
	want := u.remoteSum
	u.mu.Unlock()
	if want == "" {
		return fail
	}
	me, err := os.Executable()
	if err != nil {
		return fail
	}
	if p, e := filepath.EvalSymlinks(me); e == nil {
		me = p
	}
	dir := filepath.Dir(me)
	tmp := filepath.Join(dir, "kombain-start.new.exe")
	f, err := os.Create(tmp)
	if err != nil {
		return errors.New("В эту папку нельзя записать обновление. Скачай новую версию со страницы Комбайна — кнопка ниже.")
	}
	err = fetch(updExe, updMaxExe, f)
	_ = f.Close()
	if err != nil {
		_ = os.Remove(tmp)
		return errors.New("Не скачалось — проверь интернет и нажми ещё раз.")
	}
	if got, e := fileSum(tmp); e != nil || got != want {
		_ = os.Remove(tmp)
		return errors.New("Файл скачался битым. Нажми ещё раз.")
	}
	old := me + ".old"
	_ = os.Remove(old)
	if err = os.Rename(me, old); err != nil {
		_ = os.Remove(tmp)
		return fail
	}
	if err = os.Rename(tmp, me); err != nil {
		_ = os.Rename(old, me) // вернуть как было
		_ = os.Remove(tmp)
		return fail
	}
	if err = exec.Command(me).Start(); err != nil {
		return errors.New("Обновил. Закрой окно и запусти Комбайн заново.")
	}
	restart()
	return nil
}

// cleanupOld — убрать файл прошлой версии, оставшийся после обновления.
func cleanupOld() {
	if me, err := os.Executable(); err == nil {
		_ = os.Remove(me + ".old")
		_ = os.Remove(filepath.Join(filepath.Dir(me), "kombain-start.new.exe"))
	}
}
