// Пакет kbcore — мост между Android-приложением и логикой установщика.
// Логика (вход по SSH, установка прокси и бота) та же, что у kombain-start.exe:
// gen.sh копирует сюда starter/backend.go.
package kbcore

import (
	"encoding/json"
	"errors"
	"sync"
)

var (
	instMu sync.Mutex
	inst   = newInstaller()
)

func current() *installer { instMu.Lock(); defer instMu.Unlock(); return inst }

type reply struct {
	Result interface{} `json:"result"`
	Error  string      `json:"error,omitempty"`
}

// Call вызывает шаг установщика по имени. args — JSON-массив строк.
// Ответ — JSON {"result": ..., "error": "..."}; error пустой — всё хорошо.
func Call(name, args string) string {
	var raw []json.RawMessage
	_ = json.Unmarshal([]byte(args), &raw)
	arg := func(i int) string {
		var s string
		if i < len(raw) {
			_ = json.Unmarshal(raw[i], &s)
		}
		return s
	}
	a := current()
	var res interface{}
	var err error
	switch name {
	case "loginServer":
		err = a.login(arg(0), arg(1), arg(2))
	case "installBot":
		err = a.install(arg(0))
	case "installerState":
		res = a.snapshot()
	case "retryOwner":
		err = a.retryWait()
	case "installProxy":
		err = a.installProxy()
	case "needLogin":
		res = a.needLogin()
	case "proxyLink":
		res, err = a.proxyLink()
	default:
		err = errors.New("Неизвестная команда.")
	}
	r := reply{Result: res}
	if err != nil {
		r.Error = err.Error()
	}
	out, _ := json.Marshal(r)
	return string(out)
}

// Close рвёт соединение с сервером и начинает с чистого листа (приложение закрыли).
func Close() {
	instMu.Lock()
	old := inst
	inst = newInstaller()
	instMu.Unlock()
	old.close()
}
