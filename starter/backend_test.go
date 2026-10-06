package main

import (
	"bufio"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func TestSafeLogSplitSecret(t *testing.T) {
	const token = "1234567890:AAH_super_secret"
	var result strings.Builder
	w := &safeLog{secret: token, emit: func(s string) { result.WriteString(s) }}
	chunks := []string{"begin\n12345", "67890:AAH_", "super_secret\nURL /bot1234567890:OTHER_SECRET/getMe\n", "done"}
	for _, s := range chunks {
		if n, err := w.Write([]byte(s)); err != nil || n != len(s) {
			t.Fatal(n, err)
		}
	}
	w.flush()
	got := result.String()
	if strings.Contains(got, token) || strings.Contains(got, "OTHER_SECRET") {
		t.Fatal("secret leaked")
	}
	if !strings.Contains(got, "begin\n") || !strings.Contains(got, "done") || strings.Count(got, "[токен скрыт]") != 2 {
		t.Fatalf("unexpected log: %q", got)
	}
}

func TestSSHInstallerProtocol(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	config := &ssh.ServerConfig{PasswordCallback: func(meta ssh.ConnMetadata, p []byte) (*ssh.Permissions, error) {
		if meta.User() != "root" || string(p) != "test-pass" {
			return nil, fmt.Errorf("bad credentials")
		}
		return nil, nil
	}}
	config.AddHostKey(signer)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	tokens := make(chan string, 1)
	commands := make(chan string, 4)
	go func() {
		conn, e := listener.Accept()
		if e != nil {
			return
		}
		server, chans, reqs, e := ssh.NewServerConn(conn, config)
		if e != nil {
			return
		}
		defer server.Close()
		go ssh.DiscardRequests(reqs)
		for ch := range chans {
			channel, requests, e := ch.Accept()
			if e != nil {
				return
			}
			go func() {
				defer channel.Close()
				for req := range requests {
					if req.Type != "exec" {
						_ = req.Reply(false, nil)
						continue
					}
					var payload struct{ Command string }
					if ssh.Unmarshal(req.Payload, &payload) != nil {
						return
					}
					commands <- payload.Command
					_ = req.Reply(true, nil)
					switch payload.Command {
					case installCommand:
						token, _ := bufio.NewReader(channel).ReadString('\n')
						tokens <- token
						fmt.Fprintln(channel.Stderr(), "install log", strings.TrimSpace(token))
						fmt.Fprintln(channel, `{"bot":"test_kombain_bot","code":"012345"}`)
					case ownerCommand:
						fmt.Fprintln(channel, "12345")
					}
					_, _ = channel.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{0}))
					return
				}
			}()
		}
	}()
	fp := ""
	client, err := connect(listener.Addr().String(), "root", "test-pass", func(s string) { fp = s })
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if fp != ssh.FingerprintSHA256(signer.PublicKey()) {
		t.Fatal("fingerprint not preserved")
	}
	a := newInstaller()
	a.client = client
	a.state.Phase = "token"
	defer a.close()
	const token = "1234567890:AAH_test_token"
	if err = a.install(token); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) && a.snapshot().Phase != "done" {
		time.Sleep(10 * time.Millisecond)
	}
	s := a.snapshot()
	if s.Phase != "done" || s.Code != "012345" || s.Bot != "test_kombain_bot" || s.Step != 3 {
		t.Fatalf("bad state: %+v", s)
	}
	if strings.Contains(s.Log, token) {
		t.Fatal("token in UI log")
	}
	select {
	case sent := <-tokens:
		if sent != token+"\n" {
			t.Fatal("stdin changed")
		}
	default:
		t.Fatal("no stdin received")
	}
	first, second := <-commands, <-commands
	if first != installCommand || second != ownerCommand || strings.Contains(first, token) {
		t.Fatal("command protocol changed")
	}
	data, _ := json.Marshal(s)
	if strings.Contains(string(data), token) || strings.Contains(string(data), "test-pass") {
		t.Fatal("secret stored in snapshot")
	}
}

func TestInputsAndClosedState(t *testing.T) {
	a := newInstaller()
	if a.login("not-an-ip", "root", "test") == nil {
		t.Fatal("bad IP accepted")
	}
	if a.install("missing-colon") == nil {
		t.Fatal("bad token accepted")
	}
	if a.install("123:token\nextra") == nil {
		t.Fatal("multiline token accepted")
	}
	a.close()
	if a.login("127.0.0.1", "root", "test") == nil {
		t.Fatal("closed installer accepted login")
	}
	if a.update(0, func(s *Snapshot) { s.Code = "123456" }) {
		t.Fatal("stale state accepted")
	}
}
