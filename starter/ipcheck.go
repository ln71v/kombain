package main

// Проверка IP сервера до установки: открывается ли он из России.
// Два способа сразу:
//  1. Отсюда — стучимся на IP:порт с этого компа или телефона и ждём приветствие SSH («SSH-2.0…»).
//     Это честнее всего: видно, пускает ли именно твой провайдер.
//  2. check-host.net — их узлы в России (у разных провайдеров) стучатся на тот же IP:порт.
// На сервер ничего не ставится и пароль не нужен.

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// IPCheck — что видит окно. Verdict: "green" — можно ставить, "red" — не годится, "yellow" — проверь ещё раз.
type IPCheck struct {
	Running bool   `json:"running"`
	Stage   string `json:"stage"`
	Address string `json:"address"`
	Verdict string `json:"verdict"`
	Title   string `json:"title"`
	Advice  string `json:"advice"`
	Self    string `json:"self"`
	Russia  string `json:"russia"`
}

var (
	checkHostURL     = "https://check-host.net" // тесты подменяют
	ipCheckDial      = 8 * time.Second
	ipCheckBanner    = 8 * time.Second
	ipCheckWait      = 20 * time.Second // сколько ждём узлы check-host
	ipCheckPoll      = 2 * time.Second
	ipCheckAnyTarget = false // тесты: разрешить 127.0.0.1
	ipCheckMaxRU     = 6
)

var ipc struct {
	mu  sync.Mutex
	gen int
	res IPCheck
}

// parseCheckTarget: «IP» или «IP:порт» → host:port. Имена не принимаем — только IP от хостера.
func parseCheckTarget(s string) (string, net.IP, error) {
	s = strings.TrimSpace(s)
	host, port := s, "22"
	if h, p, err := net.SplitHostPort(s); err == nil {
		host, port = h, p
	}
	host = strings.Trim(host, "[]")
	ip := net.ParseIP(host)
	if ip == nil {
		return "", nil, errors.New("Вставь IP сервера, который прислал хостер. Пример: 203.0.113.10 или 203.0.113.10:49222")
	}
	if n, err := strconv.Atoi(port); err != nil || n < 1 || n > 65535 {
		return "", nil, errors.New("Порт — число от 1 до 65535. Пример: 203.0.113.10:49222")
	}
	if !ipCheckAnyTarget && (ip.IsLoopback() || ip.IsPrivate() || ip.IsUnspecified() || ip.IsLinkLocalUnicast() || ip.IsMulticast()) {
		return "", nil, errors.New("Это адрес домашней сети, а не сервера. Вставь IP из письма хостера.")
	}
	return net.JoinHostPort(ip.String(), port), ip, nil
}

// ipCheckStart запускает проверку в фоне. Результат — ipCheckState().
func ipCheckStart(addr string) error {
	target, ip, err := parseCheckTarget(addr)
	if err != nil {
		return err
	}
	ipc.mu.Lock()
	if ipc.res.Running {
		ipc.mu.Unlock()
		return errors.New("Уже проверяю, подожди.")
	}
	ipc.gen++
	gen := ipc.gen
	ipc.res = IPCheck{Running: true, Stage: "Стучусь на сервер…", Address: target}
	ipc.mu.Unlock()
	go func() {
		res := runIPCheck(target, ip, func(stage string) {
			ipc.mu.Lock()
			if ipc.gen == gen {
				ipc.res.Stage = stage
			}
			ipc.mu.Unlock()
		})
		ipc.mu.Lock()
		if ipc.gen == gen {
			ipc.res = res
		}
		ipc.mu.Unlock()
	}()
	return nil
}

func ipCheckState() IPCheck {
	ipc.mu.Lock()
	defer ipc.mu.Unlock()
	return ipc.res
}

// Итог стука с этого устройства.
const (
	selfOK      = "ok"      // пришло «SSH-…»
	selfSilent  = "silent"  // соединилось, но данные не идут
	selfRefused = "refused" // сервер ответил «порт закрыт»
	selfFail    = "fail"    // не достучались
)

func knockSelf(target string) string {
	c, err := net.DialTimeout("tcp", target, ipCheckDial)
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "refused") {
			return selfRefused
		}
		return selfFail
	}
	defer c.Close()
	_ = c.SetReadDeadline(time.Now().Add(ipCheckBanner))
	buf := make([]byte, 64)
	n, _ := io.ReadAtLeast(c, buf, 4)
	if n >= 4 && string(buf[:4]) == "SSH-" {
		return selfOK
	}
	return selfSilent
}

// ruResult: сколько узлов в России достучались. total == 0 — узнать не вышло.
type ruResult struct{ ok, total int }

var chClient = &http.Client{Timeout: 10 * time.Second}

func chGet(path string, out interface{}) error {
	req, err := http.NewRequest("GET", checkHostURL+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "kombain")
	resp, err := chClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("check-host: %d", resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(out)
}

func knockRussia(target string) ruResult {
	var hosts struct {
		Nodes map[string]struct {
			Location []string `json:"location"`
		} `json:"nodes"`
	}
	if err := chGet("/nodes/hosts", &hosts); err != nil {
		return ruResult{}
	}
	var ru []string
	for name, n := range hosts.Nodes {
		if len(n.Location) > 0 && strings.EqualFold(n.Location[0], "ru") {
			ru = append(ru, name)
		}
	}
	if len(ru) == 0 {
		return ruResult{}
	}
	sort.Strings(ru)
	if len(ru) > ipCheckMaxRU {
		ru = ru[:ipCheckMaxRU]
	}
	q := url.Values{"host": {target}}
	for _, n := range ru {
		q.Add("node", n)
	}
	var start struct {
		OK        int    `json:"ok"`
		RequestID string `json:"request_id"`
	}
	if err := chGet("/check-tcp?"+q.Encode(), &start); err != nil || start.OK != 1 || start.RequestID == "" {
		return ruResult{}
	}
	id := url.PathEscape(start.RequestID)
	deadline := time.Now().Add(ipCheckWait)
	var res ruResult
	for {
		time.Sleep(ipCheckPoll)
		var out map[string]json.RawMessage
		if err := chGet("/check-result/"+id, &out); err == nil {
			res = ruResult{}
			pending := 0
			for _, n := range ru {
				raw, ok := out[n]
				if !ok {
					continue
				}
				var items []map[string]interface{}
				if string(raw) == "null" || json.Unmarshal(raw, &items) != nil {
					pending++
					continue
				}
				res.total++
				if len(items) > 0 && items[0]["error"] == nil && items[0]["time"] != nil {
					res.ok++
				}
			}
			if pending == 0 && res.total > 0 {
				return res
			}
		}
		if time.Now().After(deadline) {
			return res // кто не успел — не считаем
		}
	}
}

func runIPCheck(target string, ip net.IP, stage func(string)) IPCheck {
	var self string
	var ru ruResult
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); self = knockSelf(target) }()
	if ip.To4() != nil {
		wg.Add(1)
		go func() { defer wg.Done(); ru = knockRussia(target) }()
	}
	stage("Стучусь на сервер со своего интернета и с узлов в России… до 30 секунд")
	wg.Wait()
	return verdict(target, self, ru)
}

func verdict(target, self string, ru ruResult) IPCheck {
	r := IPCheck{Address: target}
	switch self {
	case selfOK:
		r.Self = "✅ С твоего интернета — открывается"
	case selfSilent:
		r.Self = "⚠️ С твоего интернета — соединилось, но данные не идут"
	case selfRefused:
		r.Self = "⚠️ С твоего интернета — сервер ответил «порт закрыт»"
	default:
		r.Self = "❌ С твоего интернета — не открывается"
	}
	ruOK := ru.total > 0 && ru.ok*2 >= ru.total // половина и больше
	switch {
	case ru.total == 0:
		r.Russia = "check-host.net не ответил — проверил только с твоего интернета"
	case ru.ok == ru.total:
		r.Russia = fmt.Sprintf("✅ Узлы в России — открывается у всех (%d из %d)", ru.ok, ru.total)
	case ru.ok == 0:
		r.Russia = fmt.Sprintf("❌ Узлы в России — не открывается ни у кого (0 из %d)", ru.total)
	default:
		r.Russia = fmt.Sprintf("⚠️ Узлы в России — открывается у %d из %d", ru.ok, ru.total)
	}
	const bad = "Пиши в поддержку хостера: «Смените IP на не заблокированный в РФ, из другой подсети». " +
		"Не меняют — заявка на удаление и возврат денег, пока не вышел срок. На этот IP ничего не ставь."
	switch {
	case self == selfOK && (ruOK || ru.total == 0):
		r.Verdict, r.Title = "green", "Работает — пользуйся"
		r.Advice = "IP из России открывается. Жми «Сервер есть →» и ставь Комбайн дальше по шагам."
	case self == selfSilent:
		r.Verdict, r.Title = "red", "Не работает — IP глушат"
		r.Advice = "Соединение есть, но данные не проходят — так режут заблокированные адреса. Работать не будет или будет плохо. " + bad
	case self == selfRefused:
		r.Verdict, r.Title = "yellow", "Сервер живой, но порт закрыт"
		r.Advice = "Похоже, SSH у сервера на другом порту. Глянь порт в письме хостера и проверь так: IP:порт. Если порт 22 — подожди 5 минут, сервер ещё запускается."
	case self == selfOK && !ruOK:
		r.Verdict, r.Title = "yellow", "У тебя открывается, у остальных в России — нет"
		r.Advice = "Включён VPN на этом устройстве? Выключи и проверь ещё раз. Если VPN нет — IP в бане у многих провайдеров, лучше сменить. " + bad
	case ru.total > 0 && ru.ok > 0:
		r.Verdict, r.Title = "red", "Не работает у твоего провайдера"
		r.Advice = "У части провайдеров в России открывается, а у тебя — нет. Тебе он работать не будет. " + bad
	default:
		r.Verdict, r.Title = "red", "Не работает — из России не открывается"
		r.Advice = "Только что купил? Подожди 5 минут и проверь ещё раз — сервер может ещё запускаться. Снова красное — значит, IP в бане. " + bad
	}
	return r
}
