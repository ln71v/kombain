package kbcore

import (
	"encoding/json"
	"testing"
)

func call(t *testing.T, name string, args ...string) reply {
	t.Helper()
	b, _ := json.Marshal(args)
	var r reply
	if err := json.Unmarshal([]byte(Call(name, string(b))), &r); err != nil {
		t.Fatal(err)
	}
	return r
}

func TestBridge(t *testing.T) {
	defer Close()
	if r := call(t, "installerState"); r.Error != "" || r.Result.(map[string]interface{})["phase"] != "login" {
		t.Fatalf("state: %+v", r)
	}
	if r := call(t, "loginServer", "не-ip", "root", "x"); r.Error == "" {
		t.Fatal("ждала ошибку про IP")
	}
	if r := call(t, "loginServer", "203.0.113.10", "root", ""); r.Error == "" {
		t.Fatal("ждала ошибку про пароль")
	}
	if r := call(t, "installBot", "123:abc"); r.Error == "" {
		t.Fatal("без входа бот ставиться не должен")
	}
	if r := call(t, "proxyLink"); r.Error == "" {
		t.Fatal("без прокси ссылки быть не должно")
	}
	if r := call(t, "needLogin"); r.Result != true {
		t.Fatalf("needLogin: %+v", r)
	}
	if r := call(t, "чепуха"); r.Error == "" {
		t.Fatal("ждала ошибку на неизвестную команду")
	}
}
