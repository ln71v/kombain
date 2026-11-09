package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestParseCheckTarget(t *testing.T) {
	ok := map[string]string{
		"203.0.113.10":         "203.0.113.10:22",
		" 203.0.113.10:49222 ": "203.0.113.10:49222",
	}
	for in, want := range ok {
		got, _, err := parseCheckTarget(in)
		if err != nil || got != want {
			t.Fatalf("%q → %q, %v (ждала %q)", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "example.com", "203.0.113.10:0", "203.0.113.10:70000",
		"2001:db8::1", "[2001:db8::1]:22", "::ffff:203.0.113.10", "::ffff:127.0.0.1",
		"192.168.1.1", "127.0.0.1", "10.0.0.5:22", "0.0.0.1", "100.64.0.1", "100.127.255.254",
		"198.18.0.1", "169.254.1.1", "172.16.0.1", "240.0.0.1", "255.255.255.255", "224.0.0.1"} {
		if _, _, err := parseCheckTarget(bad); err == nil {
			t.Fatalf("%q должен быть отвергнут", bad)
		}
	}
	for _, good := range []string{"100.63.0.1", "100.128.0.1", "198.20.0.1", "8.8.8.8"} {
		if _, _, err := parseCheckTarget(good); err != nil {
			t.Fatalf("%q должен пройти: %v", good, err)
		}
	}
}

func TestVerdict(t *testing.T) {
	cases := []struct {
		self string
		ru   ruResult
		want string
	}{
		{selfOK, ruResult{ok: 6, total: 6}, "green"},
		{selfOK, ruResult{ok: 2, total: 2}, "green"},
		{selfOK, ruResult{ok: 5, fail: 1, total: 6}, "red"}, // хоть один не достучался — не брать
		{selfOK, ruResult{ok: 1, fail: 1, total: 2}, "red"}, // Германия 09.11
		{selfOK, ruResult{ok: 1, total: 2}, "yellow"},       // второй узел не успел — НЕ зелёный
		{selfOK, ruResult{ok: 0, total: 6}, "yellow"},       // никто не успел
		{selfOK, ruResult{ok: 5, refused: 1, total: 6}, "red"},
		{selfOK, ruResult{fail: 6, total: 6}, "red"},
		{selfOK, ruResult{}, "yellow"}, // check-host молчит — не проверить
		{selfSilent, ruResult{ok: 6, total: 6}, "red"},
		{selfFail, ruResult{ok: 6, total: 6}, "red"},
		{selfFail, ruResult{ok: 1, fail: 1, total: 2}, "red"},
		{selfFail, ruResult{}, "red"},
		{selfRefused, ruResult{refused: 6, total: 6}, "yellow"}, // сервер ещё запускается
		{selfRefused, ruResult{fail: 6, total: 6}, "red"},       // у тебя RST, у России тишина — бан
		{selfRefused, ruResult{ok: 6, total: 6}, "red"},
		{selfRefused, ruResult{}, "red"},
	}
	for _, c := range cases {
		v := verdict("203.0.113.10:22", c.self, c.ru)
		if v.Verdict != c.want || v.Title == "" || v.Advice == "" || v.Self == "" || v.Russia == "" {
			t.Fatalf("%s %+v → %+v (ждала %s)", c.self, c.ru, v, c.want)
		}
	}
}

// Сервер, который пишет banner, и сервер, который молчит.
func listen(t *testing.T, banner string) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			if banner != "" {
				_, _ = c.Write([]byte(banner))
			}
			go func() { time.Sleep(3 * time.Second); c.Close() }()
		}
	}()
	return l.Addr().String()
}

func TestKnockSelf(t *testing.T) {
	old := ipCheckBanner
	ipCheckBanner = 500 * time.Millisecond
	defer func() { ipCheckBanner = old }()
	if got := knockSelf(listen(t, "SSH-2.0-OpenSSH_9.6\r\n")); got != selfOK {
		t.Fatal("ssh:", got)
	}
	// По правилам SSH перед приветствием бывают другие строки — это рабочий сервер.
	if got := knockSelf(listen(t, "Welcome to this server\r\nSSH-2.0-OpenSSH_9.6\r\n")); got != selfOK {
		t.Fatal("ssh с баннером:", got)
	}
	for _, partial := range []string{"SSH-", "SSH-2.0-OpenSSH", "SSH-1.5-old\r\n", "SSH-2.0-\r\n"} {
		if got := knockSelf(listen(t, partial)); got != selfSilent {
			t.Fatalf("неполное/неверное приветствие %q: %s", partial, got)
		}
	}
	if got := knockSelf(listen(t, "")); got != selfSilent {
		t.Fatal("тишина:", got)
	}
	if got := knockSelf(listen(t, "HTTP/1.1 400 Bad Request\r\n\r\n")); got != selfSilent {
		t.Fatal("не SSH:", got)
	}
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := l.Addr().String()
	l.Close()
	if got := knockSelf(addr); got != selfRefused {
		t.Fatal("закрытый порт:", got)
	}
}

// Поддельный check-host: узлы ru1, ru2 в России и de1 в Германии.
// results — что отдавать на каждый опрос (по очереди, последний повторяется).
func fakeCheckHost(t *testing.T, polls *int32, results ...string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept") != "application/json" {
			http.Error(w, "accept", 400)
			return
		}
		switch {
		case r.URL.Path == "/nodes/hosts":
			_, _ = w.Write([]byte(`{"nodes":{"ru1.node.check-host.net":{"location":["ru","Russia","Moscow"]},
				"ru2.node.check-host.net":{"location":["ru","Russia","Saint Petersburg"]},
				"de1.node.check-host.net":{"location":["de","Germany","Falkenstein"]}}}`))
		case r.URL.Path == "/check-tcp":
			nodes := r.URL.Query()["node"]
			if r.URL.Query().Get("host") != "203.0.113.10:22" || len(nodes) != 2 || strings.Contains(strings.Join(nodes, ","), "de1") {
				http.Error(w, "bad query "+r.URL.RawQuery, 400)
				return
			}
			_, _ = w.Write([]byte(`{"ok":1,"request_id":"abc123"}` + "\n"))
		case r.URL.Path == "/check-result/abc123":
			i := int(atomic.AddInt32(polls, 1)) - 1
			if i >= len(results) {
				i = len(results) - 1
			}
			_, _ = w.Write([]byte(results[i]))
		default:
			http.NotFound(w, r)
		}
	}))
}

const (
	chOK      = `[{"time":0.05,"address":"203.0.113.10"}]`
	chTimeout = `[{"error":"Connection timed out"}]`
	chRefused = `[{"error":"Connection refused"}]`
)

func chRes(ru1, ru2 string) string {
	return `{"ru1.node.check-host.net":` + ru1 + `,"ru2.node.check-host.net":` + ru2 + `}`
}

func withFakeCheckHost(t *testing.T, wait time.Duration, results ...string) *int32 {
	t.Helper()
	var polls int32
	srv := fakeCheckHost(t, &polls, results...)
	oldURL, oldPoll, oldWait := checkHostURL, ipCheckPoll, ipCheckWait
	checkHostURL, ipCheckPoll, ipCheckWait = srv.URL, 10*time.Millisecond, wait
	t.Cleanup(func() { srv.Close(); checkHostURL, ipCheckPoll, ipCheckWait = oldURL, oldPoll, oldWait })
	return &polls
}

func TestKnockRussia(t *testing.T) {
	// Первый опрос — второй узел думает, второй опрос — таймаут. Итог: 1 ок, 1 не достучался.
	polls := withFakeCheckHost(t, 5*time.Second, chRes(chOK, "null"), chRes(chOK, chTimeout))
	got := knockRussia("203.0.113.10:22")
	if got != (ruResult{ok: 1, fail: 1, total: 2}) || *polls < 2 {
		t.Fatalf("%+v, опросов %d", got, *polls)
	}
}

// Главный ложный зелёный из ревью: один узел «ок», второй так и не ответил (или пропал из ответа).
func TestKnockRussiaPendingIsNotGreen(t *testing.T) {
	for _, res := range []string{chRes(chOK, "null"), `{"ru1.node.check-host.net":` + chOK + `}`} {
		withFakeCheckHost(t, 300*time.Millisecond, res)
		start := time.Now()
		got := knockRussia("203.0.113.10:22")
		if got != (ruResult{ok: 1, total: 2}) {
			t.Fatalf("%s → %+v", res, got)
		}
		if time.Since(start) > 2*time.Second {
			t.Fatal("не уложилась в общий предел времени")
		}
		if v := verdict("203.0.113.10:22", selfOK, got); v.Verdict == "green" {
			t.Fatalf("ложный зелёный: %+v", v)
		}
	}
}

func TestKnockRussiaRefusedAndGarbage(t *testing.T) {
	withFakeCheckHost(t, 5*time.Second, chRes(chRefused, `"мусор"`))
	if got := knockRussia("203.0.113.10:22"); got != (ruResult{refused: 1, fail: 1, total: 2}) {
		t.Fatalf("%+v", got)
	}
}

func TestKnockRussiaDown(t *testing.T) {
	old := checkHostURL
	checkHostURL = "http://127.0.0.1:1"
	defer func() { checkHostURL = old }()
	if got := knockRussia("203.0.113.10:22"); got.total != 0 {
		t.Fatalf("%+v", got)
	}
}

// Медленный check-host: каждый ответ — через 2 с, общий предел 500 мс. Проверка не должна висеть.
func TestKnockRussiaSlow(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Second)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()
	oldURL, oldWait := checkHostURL, ipCheckWait
	checkHostURL, ipCheckWait = srv.URL, 500*time.Millisecond
	defer func() { checkHostURL, ipCheckWait = oldURL, oldWait }()
	start := time.Now()
	if got := knockRussia("203.0.113.10:22"); got.total != 0 {
		t.Fatalf("%+v", got)
	}
	if d := time.Since(start); d > 1500*time.Millisecond {
		t.Fatalf("висела %v", d)
	}
}

func waitIPCheck(t *testing.T) IPCheck {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for ipCheckState().Running {
		if time.Now().After(deadline) {
			t.Fatal("проверка не закончилась")
		}
		time.Sleep(20 * time.Millisecond)
	}
	return ipCheckState()
}

func TestIPCheckStartState(t *testing.T) {
	oldAny, oldURL, oldBanner := ipCheckAnyTarget, checkHostURL, ipCheckBanner
	ipCheckAnyTarget, checkHostURL, ipCheckBanner = true, "http://127.0.0.1:1", 500*time.Millisecond
	// Восстанавливать — только когда фоновая проверка закончилась, иначе гонка за переменные.
	defer func() {
		for i := 0; i < 1500 && ipCheckState().Running; i++ {
			time.Sleep(20 * time.Millisecond)
		}
		ipCheckAnyTarget, checkHostURL, ipCheckBanner = oldAny, oldURL, oldBanner
	}()
	if err := ipCheckStart("не ip"); err == nil {
		t.Fatal("ждала ошибку")
	}
	addr := listen(t, "SSH-2.0-test\r\n")
	if err := ipCheckStart(addr); err != nil {
		t.Fatal(err)
	}
	if err := ipCheckStart(addr); err == nil || !strings.Contains(err.Error(), "Уже проверяю") {
		t.Fatal("второй запуск во время проверки должен отказать:", err)
	}
	st := waitIPCheck(t)
	// check-host недоступен — узлы РФ не проверены, значит не зелёный.
	if st.Verdict != "yellow" || st.Address != addr {
		b, _ := json.Marshal(st)
		t.Fatalf("%s", b)
	}
	// Сброс (приложение закрыли) — пусто, и новую проверку можно запускать сразу.
	if err := ipCheckStart(addr); err != nil {
		t.Fatal(err)
	}
	ipCheckReset()
	if st := ipCheckState(); st.Running || st.Address != "" {
		t.Fatalf("после сброса: %+v", st)
	}
	if err := ipCheckStart(addr); err != nil {
		t.Fatal("после сброса должна запускаться:", err)
	}
	waitIPCheck(t)
}
