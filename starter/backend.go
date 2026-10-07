package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"regexp"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

const kbURL = "https://raw.githubusercontent.com/ln71v/kombain/main/kombain.sh"

// Команда и протокол установки взяты из исходного main.go.
const installCommand = "command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl >/dev/null; }; " +
	"read -r KB_BOT_TOKEN; export KB_BOT_TOKEN; " +
	"curl -fsSL " + kbURL + " -o /tmp/kombain-start.sh && bash /tmp/kombain-start.sh cli bot install"

const ownerCommand = "bash /opt/kombain/src/kombain.sh cli bot owner"

// Telegram-прокси: для тех, у кого Telegram без VPN не грузится, — иначе до бота не дойти.
const proxyCommand = "command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl >/dev/null; }; " +
	"curl -fsSL " + kbURL + " -o /tmp/kombain-start.sh && bash /tmp/kombain-start.sh cli tgproxy install"

var (
	proxyTGPattern  = regexp.MustCompile(`^tg://proxy\?server=[0-9.]{7,15}&port=[0-9]{2,5}&secret=ee[0-9a-f]{20,200}$`)
	proxyWebPattern = regexp.MustCompile(`^https://t\.me/proxy\?server=[0-9.]{7,15}&port=[0-9]{2,5}&secret=ee[0-9a-f]{20,200}$`)
	base64Pattern   = regexp.MustCompile(`^[A-Za-z0-9+/]+={0,2}$`)
)

type Snapshot struct {
	Phase       string `json:"phase"`
	Error       string `json:"error"`
	Fingerprint string `json:"fingerprint"`
	Network     string `json:"network"`
	Log         string `json:"log"`
	Bot         string `json:"bot"`
	Code        string `json:"code"`
	Step        int    `json:"step"`
	ProxyTG     string `json:"proxyTG"`
	ProxyWeb    string `json:"proxyWeb"`
	ProxyQR     string `json:"proxyQR"`
}

type installer struct {
	mu         sync.Mutex
	state      Snapshot
	client     *ssh.Client
	busy       bool
	closed     bool
	generation uint64
}

func newInstaller() *installer          { return &installer{state: Snapshot{Phase: "login"}} }
func (a *installer) snapshot() Snapshot { a.mu.Lock(); defer a.mu.Unlock(); return a.state }
func (a *installer) close() {
	a.mu.Lock()
	a.closed = true
	a.generation++
	c := a.client
	a.client = nil
	a.mu.Unlock()
	if c != nil {
		_ = c.Close()
	}
}
func (a *installer) update(g uint64, f func(*Snapshot)) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed || a.generation != g {
		return false
	}
	f(&a.state)
	return true
}
func (a *installer) finish(g uint64, phase, message string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed || a.generation != g {
		return
	}
	a.busy = false
	a.state.Phase = phase
	a.state.Error = message
}

func (a *installer) login(host, user, pass string) error {
	host = strings.TrimSpace(host)
	user = strings.TrimSpace(user)
	if user == "" {
		user = "root"
	}
	// IP-адрес, как в форме; IPv6 тоже поддерживается.
	if net.ParseIP(strings.Trim(host, "[]")) == nil {
		return errors.New("Введи IP сервера, который прислал хостер.")
	}
	host = strings.Trim(host, "[]")
	if pass == "" {
		return errors.New("Введи пароль от сервера.")
	}
	a.mu.Lock()
	if a.closed || a.busy {
		a.mu.Unlock()
		return errors.New("Подожди, выполняю предыдущий шаг.")
	}
	old := a.client
	a.client = nil
	a.generation++
	g := a.generation
	a.busy = true
	a.state = Snapshot{Phase: "connecting"}
	a.mu.Unlock()
	if old != nil {
		_ = old.Close()
	}
	go func() {
		c, err := connect(host, user, pass, func(fp string) { a.update(g, func(s *Snapshot) { s.Fingerprint = fp }) })
		pass = "" // Пароль не сохраняется в состоянии, файлах или журнале.
		if err != nil {
			var nerr net.Error
			msg := "Не получилось зайти на сервер. Проверь параметры SSH и попробуй ещё раз."
			switch {
			case strings.Contains(err.Error(), "unable to authenticate"):
				msg = "Неверный логин или пароль. Давай ещё раз."
			case errors.As(err, &nerr) || strings.Contains(err.Error(), "connect"):
				msg = "Сервер не отвечает. Проверь IP и что сервер включён в панели хостера."
			}
			a.finish(g, "login", msg)
			return
		}
		if id, _ := run(c, "id -u", "", nil); id != "0" {
			_ = c.Close()
			a.finish(g, "login", "Нужен логин root (полный доступ). Возьми его у хостера в панели сервера.")
			return
		}
		org, _ := run(c, "curl -4 -fs --max-time 8 ipinfo.io/org || true", "", nil)
		a.mu.Lock()
		if a.closed || a.generation != g {
			a.mu.Unlock()
			_ = c.Close()
			return
		}
		a.client = c
		a.busy = false
		a.state.Phase = "telegram"
		a.state.Network = org
		a.state.Step = 1
		a.mu.Unlock()
	}()
	return nil
}

func connect(host, user, pass string, fingerprint func(string)) (*ssh.Client, error) {
	if _, _, err := net.SplitHostPort(host); err != nil {
		host = net.JoinHostPort(host, "22")
	}
	cfg := &ssh.ClientConfig{
		User: user,
		Auth: []ssh.AuthMethod{
			ssh.Password(pass),
			ssh.KeyboardInteractive(func(_, _ string, q []string, _ []bool) ([]string, error) {
				ans := make([]string, len(q))
				for i := range ans {
					ans[i] = pass
				}
				return ans, nil
			}),
		},
		// Как в исходнике: принять ключ и показать SHA256 пользователю.
		HostKeyCallback: func(_ string, _ net.Addr, k ssh.PublicKey) error { fingerprint(ssh.FingerprintSHA256(k)); return nil },
		Timeout:         20 * time.Second,
	}
	// Тот же SSH-протокол; deadline ограничивает также зависшее рукопожатие.
	conn, err := net.DialTimeout("tcp", host, cfg.Timeout)
	if err != nil {
		return nil, err
	}
	_ = conn.SetDeadline(time.Now().Add(cfg.Timeout))
	cc, chans, reqs, err := ssh.NewClientConn(conn, host, cfg)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	_ = conn.SetDeadline(time.Time{})
	return ssh.NewClient(cc, chans, reqs), nil
}

// stdout остаётся протоколом JSON, stderr — раскрываемым журналом.
func run(c *ssh.Client, cmd, stdin string, log io.Writer) (string, error) {
	s, err := c.NewSession()
	if err != nil {
		return "", err
	}
	defer s.Close()
	var out bytes.Buffer
	s.Stdout = &out
	s.Stderr = io.Discard
	if log != nil {
		s.Stderr = log
	}
	if stdin != "" {
		s.Stdin = strings.NewReader(stdin)
	}
	err = s.Run(cmd)
	return strings.TrimSpace(out.String()), err
}
func lastLine(s string) string { l := strings.Split(strings.TrimSpace(s), "\n"); return l[len(l)-1] }

var tokenPattern = regexp.MustCompile(`[0-9]+:[A-Za-z0-9_-]+`)

// Буфер до конца строки предотвращает утечку токена, разделённого на пакеты SSH.
// Ограничиваем и строки, и весь журнал. Он хранится только в памяти.
type safeLog struct {
	mu      sync.Mutex
	pending []byte
	secret  string
	emit    func(string)
}

func (w *safeLog) Write(b []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.pending = append(w.pending, b...)
	for {
		i := bytes.IndexByte(w.pending, '\n')
		if i < 0 {
			break
		}
		w.line(w.pending[:i+1])
		w.pending = w.pending[i+1:]
	}
	if len(w.pending) > 16384 {
		w.pending = nil
		w.emit("[Слишком длинная строка журнала скрыта]\n")
	}
	return len(b), nil
}
func (w *safeLog) line(b []byte) {
	s := strings.ToValidUTF8(string(b), "�")
	if w.secret != "" {
		s = strings.ReplaceAll(s, w.secret, "[токен скрыт]")
	}
	s = tokenPattern.ReplaceAllString(s, "[токен скрыт]")
	w.emit(s)
}
func (w *safeLog) flush() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.pending) > 0 {
		w.line(w.pending)
		w.pending = nil
	}
	w.secret = ""
}

func (a *installer) install(token string) error {
	token = strings.TrimSpace(token)
	// Проверка как в исходнике; перевод строки запрещён, чтобы stdin содержал один токен.
	if !strings.Contains(token, ":") || strings.ContainsAny(token, "\r\n\x00") {
		return errors.New("Это не токен. Скопируй длинную строку у @BotFather.")
	}
	a.mu.Lock()
	if a.closed || a.busy {
		a.mu.Unlock()
		return errors.New("Подожди, выполняю предыдущий шаг.")
	}
	if a.client == nil {
		a.mu.Unlock()
		return errors.New("Сначала войди на сервер.")
	}
	c, g := a.client, a.generation
	a.busy = true
	a.state.Phase = "installing"
	a.state.Error = ""
	a.state.Log = ""
	a.state.Step = 1
	a.mu.Unlock()
	go func() {
		log := &safeLog{secret: token, emit: func(t string) {
			a.update(g, func(s *Snapshot) {
				s.Log += t
				r := []rune(s.Log)
				if len(r) > 32000 {
					s.Log = string(r[len(r)-32000:])
				}
			})
		}}
		out, err := run(c, installCommand, token+"\n", log)
		log.flush()
		token = ""
		var info struct {
			Bot  string `json:"bot"`
			Code string `json:"code"`
		}
		if err != nil || json.Unmarshal([]byte(lastLine(out)), &info) != nil || !regexp.MustCompile(`^[0-9]{6}$`).MatchString(info.Code) || info.Bot == "" {
			a.finish(g, "install-error", "Не встало. Если в журнале написано про токен — скопируй его у @BotFather ещё раз. Проверь также связь с сервером.")
			return
		}
		if !a.update(g, func(s *Snapshot) { s.Step = 2; s.Phase = "launching" }) {
			return
		}
		// install уже запускает бота. Дополнительную команду запуска не добавляем.
		if !a.update(g, func(s *Snapshot) {
			s.Step = 3
			s.Bot = strings.TrimPrefix(info.Bot, "@")
			s.Code = info.Code
			s.Phase = "waiting"
		}) {
			return
		}
		a.waitOwner(c, g)
	}()
	return nil
}
func (a *installer) waitOwner(c *ssh.Client, g uint64) {
	for deadline := time.Now().Add(30 * time.Minute); time.Now().Before(deadline); {
		a.mu.Lock()
		alive := !a.closed && a.generation == g
		a.mu.Unlock()
		if !alive {
			return
		}
		owner, err := run(c, ownerCommand, "", nil)
		if err == nil && owner != "" && owner != "0" {
			a.finish(g, "done", "")
			return
		}
		if err != nil {
			a.finish(g, "wait-error", "Связь с сервером прервалась. Код сохранился на сервере: его можно отправить боту. Попробуй проверить ещё раз.")
			return
		}
		time.Sleep(3 * time.Second)
	}
	a.finish(g, "timeout", "Код пока не пришёл. Отправь его боту, когда будет удобно, или попробуй проверить ещё раз.")
}
func (a *installer) retryWait() error {
	a.mu.Lock()
	if a.closed || a.busy {
		a.mu.Unlock()
		return errors.New("Подожди, проверяю код.")
	}
	if a.client == nil || a.state.Code == "" {
		a.mu.Unlock()
		return errors.New("Сначала подключись к серверу.")
	}
	c, g := a.client, a.generation
	a.busy = true
	a.state.Phase = "waiting"
	a.state.Error = ""
	a.mu.Unlock()
	go a.waitOwner(c, g)
	return nil
}

// Ставит Telegram-прокси на сервер. Можно жать повторно: модуль на сервере
// при уже стоящем прокси ничего не меняет и просто отдаёт ссылку.
func (a *installer) installProxy() error {
	a.mu.Lock()
	if a.closed || a.busy {
		a.mu.Unlock()
		return errors.New("Подожди, выполняю предыдущий шаг.")
	}
	if a.client == nil {
		a.mu.Unlock()
		return errors.New("Сначала войди на сервер.")
	}
	c, g := a.client, a.generation
	a.busy = true
	a.state.Phase = "proxy-installing"
	a.state.Error = ""
	a.state.Log = ""
	a.mu.Unlock()
	go func() {
		log := &safeLog{emit: func(t string) {
			a.update(g, func(s *Snapshot) {
				s.Log += t
				r := []rune(s.Log)
				if len(r) > 32000 {
					s.Log = string(r[len(r)-32000:])
				}
			})
		}}
		out, err := run(c, proxyCommand, "", log)
		log.flush()
		tg, web, qr, ok := parseProxy(lastLine(out))
		if err != nil || !ok {
			a.finish(g, "proxy-error", "Прокси не встал. Разверни журнал ниже — там написано почему. Можно попробовать ещё раз.")
			return
		}
		a.mu.Lock()
		defer a.mu.Unlock()
		if a.closed || a.generation != g {
			return
		}
		a.busy = false
		a.state.Phase = "proxy-ready"
		a.state.ProxyTG, a.state.ProxyWeb, a.state.ProxyQR = tg, web, qr
	}()
	return nil
}

// parseProxy проверяет ответ сервера: только ссылки нужного вида и картинка base64.
func parseProxy(line string) (tg, web, qr string, ok bool) {
	var p struct {
		TG  string `json:"tg"`
		Web string `json:"web"`
		QR  string `json:"qr"`
	}
	if json.Unmarshal([]byte(line), &p) != nil || !proxyTGPattern.MatchString(p.TG) || !proxyWebPattern.MatchString(p.Web) {
		return "", "", "", false
	}
	// QR необязателен: без него остаётся ссылка.
	if len(p.QR) > 300000 || !base64Pattern.MatchString(p.QR) {
		p.QR = ""
	}
	return p.TG, p.Web, p.QR, true
}

// proxyLink отдаёт проверенную tg://-ссылку для открытия в Telegram на этом компьютере.
func (a *installer) proxyLink() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !proxyTGPattern.MatchString(a.state.ProxyTG) {
		return "", errors.New("Сначала поставь прокси.")
	}
	return a.state.ProxyTG, nil
}
