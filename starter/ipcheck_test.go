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
		"[2001:db8::1]:2222":   "[2001:db8::1]:2222",
		"2001:db8::1":          "[2001:db8::1]:22",
	}
	for in, want := range ok {
		got, _, err := parseCheckTarget(in)
		if err != nil || got != want {
			t.Fatalf("%q → %q, %v (ждала %q)", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "example.com", "203.0.113.10:0", "203.0.113.10:70000", "192.168.1.1", "127.0.0.1", "10.0.0.5:22"} {
		if _, _, err := parseCheckTarget(bad); err == nil {
			t.Fatalf("%q должен быть отвергнут", bad)
		}
	}
}

func TestVerdict(t *testing.T) {
	cases := []struct {
		self string
		ru   ruResult
		want string
	}{
		{selfOK, ruResult{6, 6}, "green"},
		{selfOK, ruResult{2, 2}, "green"},
		{selfOK, ruResult{5, 6}, "red"}, // хоть один узел не достучался — не брать
		{selfOK, ruResult{1, 2}, "red"},
		{selfOK, ruResult{0, 6}, "red"},
		{selfOK, ruResult{0, 0}, "yellow"}, // check-host молчит — не проверить
		{selfSilent, ruResult{6, 6}, "red"},
		{selfFail, ruResult{6, 6}, "red"},
		{selfFail, ruResult{1, 2}, "red"},
		{selfFail, ruResult{0, 0}, "red"},
		{selfRefused, ruResult{6, 6}, "yellow"},
	}
	for _, c := range cases {
		v := verdict("203.0.113.10:22", c.self, c.ru)
		if v.Verdict != c.want || v.Title == "" || v.Advice == "" || v.Self == "" || v.Russia == "" {
			t.Fatalf("%s %+v → %+v (ждала %s)", c.self, c.ru, v, c.want)
		}
	}
}

// Сервер, который говорит «SSH-2.0», и сервер, который молчит.
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
	if got := knockSelf(listen(t, "")); got != selfSilent {
		t.Fatal("тишина:", got)
	}
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := l.Addr().String()
	l.Close()
	if got := knockSelf(addr); got != selfRefused {
		t.Fatal("закрытый порт:", got)
	}
}

// Поддельный check-host: два узла в России (один достучался, второй — нет) и один в Германии.
func fakeCheckHost(t *testing.T, polls *int32) *httptest.Server {
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
			_, _ = w.Write([]byte(`{"ok":1,"request_id":"abc123"}`))
		case r.URL.Path == "/check-result/abc123":
			if atomic.AddInt32(polls, 1) == 1 { // первый опрос — второй узел ещё думает
				_, _ = w.Write([]byte(`{"ru1.node.check-host.net":[{"time":0.05,"address":"203.0.113.10"}],"ru2.node.check-host.net":null}`))
				return
			}
			_, _ = w.Write([]byte(`{"ru1.node.check-host.net":[{"time":0.05,"address":"203.0.113.10"}],"ru2.node.check-host.net":[{"error":"Connection timed out"}]}`))
		default:
			http.NotFound(w, r)
		}
	}))
}

func TestKnockRussia(t *testing.T) {
	var polls int32
	srv := fakeCheckHost(t, &polls)
	defer srv.Close()
	oldURL, oldPoll := checkHostURL, ipCheckPoll
	checkHostURL, ipCheckPoll = srv.URL, 10*time.Millisecond
	defer func() { checkHostURL, ipCheckPoll = oldURL, oldPoll }()
	got := knockRussia("203.0.113.10:22")
	if got.ok != 1 || got.total != 2 || polls < 2 {
		t.Fatalf("%+v, опросов %d", got, polls)
	}
	// check-host лежит — total 0, без паники
	checkHostURL = "http://127.0.0.1:1"
	if got := knockRussia("203.0.113.10:22"); got.total != 0 {
		t.Fatalf("%+v", got)
	}
}

func TestIPCheckStartState(t *testing.T) {
	oldAny, oldURL, oldBanner := ipCheckAnyTarget, checkHostURL, ipCheckBanner
	ipCheckAnyTarget, checkHostURL, ipCheckBanner = true, "http://127.0.0.1:1", 500*time.Millisecond
	defer func() { ipCheckAnyTarget, checkHostURL, ipCheckBanner = oldAny, oldURL, oldBanner }()
	if err := ipCheckStart("не ip"); err == nil {
		t.Fatal("ждала ошибку")
	}
	addr := listen(t, "SSH-2.0-test\r\n")
	if err := ipCheckStart(addr); err != nil {
		t.Fatal(err)
	}
	if err := ipCheckStart(addr); err == nil {
		t.Fatal("второй запуск во время проверки должен отказать")
	}
	deadline := time.Now().Add(15 * time.Second)
	for ipCheckState().Running {
		if time.Now().After(deadline) {
			t.Fatal("проверка не закончилась")
		}
		time.Sleep(20 * time.Millisecond)
	}
	st := ipCheckState()
	if st.Verdict != "yellow" || st.Address != addr {
		b, _ := json.Marshal(st)
		t.Fatalf("%s", b)
	}
}
