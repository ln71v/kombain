// kombain-start — установщик Комбайна для Windows.
//
// Спрашивает IP, логин и пароль от сервера, сам заходит на него по SSH,
// ставит Комбайн и бота. Дальше всё делается в Telegram.
// Пароль никуда не сохраняется и не уходит дальше твоего сервера.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/term"
)

const kbURL = "https://raw.githubusercontent.com/ln71v/kombain/main/kombain.sh"

var in = bufio.NewReader(os.Stdin)

func say(f string, a ...any) { fmt.Printf(f+"\n", a...) }

func line(prompt string) string {
	fmt.Print(prompt)
	s, _ := in.ReadString('\n')
	return strings.TrimSpace(s)
}

func secret(prompt string) string {
	fmt.Print(prompt)
	b, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Println()
	if err != nil { // не консоль — читаем как обычно
		return line("")
	}
	return strings.TrimSpace(string(b))
}

func pause() {
	fmt.Print("\nНажми Enter, чтобы закрыть окно...")
	in.ReadString('\n')
}

func fail(f string, a ...any) {
	say("\n✖ "+f, a...)
	pause()
	os.Exit(1)
}

// ───────────────────────── SSH ─────────────────────────

func connect(host, user, pass string) (*ssh.Client, error) {
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
		// Сервер новый, его отпечаток знать неоткуда: принимаем и показываем.
		HostKeyCallback: func(_ string, _ net.Addr, k ssh.PublicKey) error {
			say("  отпечаток сервера: %s", ssh.FingerprintSHA256(k))
			return nil
		},
		Timeout: 20 * time.Second,
	}
	return ssh.Dial("tcp", host, cfg)
}

// run выполняет команду на сервере. Ход работы (stderr) показывает сразу,
// stdout возвращает.
func run(c *ssh.Client, cmd, stdin string, show bool) (string, error) {
	s, err := c.NewSession()
	if err != nil {
		return "", err
	}
	defer s.Close()
	var out bytes.Buffer
	s.Stdout = &out
	if show {
		s.Stderr = &indent{w: os.Stdout}
	} else {
		s.Stderr = io.Discard
	}
	if stdin != "" {
		s.Stdin = strings.NewReader(stdin)
	}
	err = s.Run(cmd)
	return strings.TrimSpace(out.String()), err
}

// indent — вывод сервера с отступом, чтобы отличался от наших сообщений.
type indent struct {
	w     io.Writer
	start bool
}

func (p *indent) Write(b []byte) (int, error) {
	for _, ch := range b {
		if !p.start {
			p.w.Write([]byte("    "))
			p.start = true
		}
		p.w.Write([]byte{ch})
		if ch == '\n' {
			p.start = false
		}
	}
	return len(b), nil
}

func lastLine(s string) string {
	l := strings.Split(strings.TrimSpace(s), "\n")
	return l[len(l)-1]
}

// ───────────────────────── шаги ─────────────────────────

const tokenHelp = `
  Создай своего бота — это 1 минута:
   1. В Telegram найди @BotFather (с синей галочкой)
   2. Напиши ему /newbot
   3. Имя бота — любое, например «Мой сервер»
   4. Адрес бота — латиницей, в конце обязательно bot, например vasya_server_bot
   5. BotFather пришлёт длинный ключ вида 1234567890:AAH...  Это и есть токен.
  Никому его не показывай.
`

func main() {
	setupConsole()
	say("════════════════════ КОМБАЙН ════════════════════")
	say("Привет! Сейчас поставлю на твой сервер бота,")
	say("а дальше всё будешь делать прямо в Telegram.")
	say("")
	say("Понадобится то, что прислал хостер: IP сервера, логин и пароль.")
	say("Пароль никуда не сохраняю, он нужен только чтобы зайти на сервер.")
	say("")

	var c *ssh.Client
	for c == nil {
		host := line("IP сервера: ")
		if host == "" {
			continue
		}
		user := line("Логин [root]: ")
		if user == "" {
			user = "root"
		}
		pass := secret("Пароль (буквы не видны — так надо): ")
		say("\n▶ Захожу на сервер %s...", host)
		cl, err := connect(host, user, pass)
		if err != nil {
			var nerr net.Error
			switch {
			case strings.Contains(err.Error(), "unable to authenticate"):
				say("✖ Неверный логин или пароль. Давай ещё раз.\n")
			case errors.As(err, &nerr) || strings.Contains(err.Error(), "connect"):
				say("✖ Сервер не отвечает. Проверь IP и что сервер включён в панели хостера.\n")
			default:
				say("✖ Не получилось зайти: %v\n", err)
			}
			continue
		}
		c = cl
	}
	defer c.Close()
	say("✔ На сервере")

	if id, _ := run(c, "id -u", "", false); id != "0" {
		fail("Нужен логин root (полный доступ). Возьми его у хостера в панели сервера.")
	}
	if org, _ := run(c, "curl -4 -fs --max-time 8 ipinfo.io/org || true", "", false); org != "" {
		say("  сеть сервера: %s", org)
	}

	say("\n▶ Токен бота")
	say(tokenHelp)
	var info struct {
		Bot  string `json:"bot"`
		Code string `json:"code"`
	}
	for {
		token := line("Вставь токен (правой кнопкой мыши): ")
		if !strings.Contains(token, ":") {
			say("✖ Это не токен. Он выглядит так: 1234567890:AAH...\n")
			continue
		}
		say("\n▶ Ставлю Комбайн и бота. Пару минут...")
		cmd := "command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl >/dev/null; }; " +
			"read -r KB_BOT_TOKEN; export KB_BOT_TOKEN; " +
			"curl -fsSL " + kbURL + " -o /tmp/kombain-start.sh && bash /tmp/kombain-start.sh cli bot install"
		out, err := run(c, cmd, token+"\n", true)
		if err == nil && json.Unmarshal([]byte(lastLine(out)), &info) == nil && info.Code != "" {
			break
		}
		say("✖ Не встало. Если выше написано про токен — скопируй его у @BotFather ещё раз.\n")
	}
	say("✔ Бот поставлен")

	say("")
	say("════════════════ ПОСЛЕДНИЙ ШАГ ════════════════")
	say("  1. Открой в Telegram:  @%s", info.Bot)
	say("  2. Внизу нажми большую кнопку «ЗАПУСТИТЬ» (START)")
	say("     — без неё писать боту нельзя, поля для текста не будет")
	say("  3. В появившемся поле набери код:  %s  и отправь", info.Code)
	say("")
	say("Кто пришлёт код — того бот и слушается. Больше никого.")
	say("Жду код...")

	for deadline := time.Now().Add(30 * time.Minute); time.Now().Before(deadline); time.Sleep(3 * time.Second) {
		owner, err := run(c, "bash /opt/kombain/src/kombain.sh cli bot owner", "", false)
		if err == nil && owner != "" && owner != "0" {
			say("\n✔ Бот твой! Дальше всё в Telegram — это окно можно закрывать.")
			pause()
			return
		}
	}
	say("\nКод так и не пришёл. Ничего страшного: отправь боту код %s, когда будет удобно.", info.Code)
	pause()
}
