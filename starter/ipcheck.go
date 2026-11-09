package main

// Проверка IP сервера до установки: открывается ли он из России.
// Два способа сразу:
//  1. Отсюда — стучимся на IP:порт с этого компа или телефона и ждём приветствие SSH («SSH-2.0…»).
//     Это честнее всего: видно, пускает ли именно твой провайдер.
//  2. check-host.net — их узлы в России (у разных провайдеров) стучатся на тот же IP:порт.
// На сервер ничего не ставится и пароль не нужен.
//
// Правило: брать только зелёный. Зелёный — у тебя открывается И КАЖДЫЙ узел в России
// успел ответить «соединился». Не ответил хоть один — не зелёный.

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
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
	ipCheckWait      = 25 * time.Second // предел на всю часть с check-host (и на каждый запрос внутри)
	ipCheckPoll      = 2 * time.Second
	ipCheckAnyTarget = false // тесты: разрешить 127.0.0.1
	ipCheckMaxRU     = 20    // сколько узлов РФ берём (у check-host их меньше — берём все)
)

var ipc struct {
	mu  sync.Mutex
	gen int
	res IPCheck
}

// Не адреса серверов в интернете: частные, провайдерские (CGNAT), VPN-интерфейсы, служебные.
func internalIPv4(ip4 net.IP) bool {
	return ip4[0] == 0 || ip4[0] == 10 || ip4[0] == 127 || ip4[0] >= 224 ||
		(ip4[0] == 100 && ip4[1] >= 64 && ip4[1] <= 127) || // CGNAT провайдера, Tailscale
		(ip4[0] == 169 && ip4[1] == 254) ||
		(ip4[0] == 172 && ip4[1] >= 16 && ip4[1] <= 31) ||
		(ip4[0] == 192 && ip4[1] == 168) ||
		(ip4[0] == 192 && ip4[1] == 0 && ip4[2] == 0) ||
		(ip4[0] == 198 && (ip4[1] == 18 || ip4[1] == 19)) // TUN у Hiddify, sing-box
}

// parseCheckTarget: «IP» или «IP:порт» → host:port. Только IPv4 — узлы check-host проверяют его.
func parseCheckTarget(s string) (string, net.IP, error) {
	s = strings.TrimSpace(s)
	host, port := s, "22"
	if h, p, err := net.SplitHostPort(s); err == nil {
		host, port = h, p
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	if ip == nil || ip.To4() == nil || strings.Contains(host, ":") {
		return "", nil, errors.New("Вставь IP сервера из письма хостера — четыре числа через точку. Пример: 203.0.113.10 или 203.0.113.10:49222")
	}
	ip = ip.To4()
	if n, err := strconv.Atoi(port); err != nil || n < 1 || n > 65535 {
		return "", nil, errors.New("Порт — число от 1 до 65535. Пример: 203.0.113.10:49222")
	}
	if !ipCheckAnyTarget && internalIPv4(ip) {
		return "", nil, errors.New("Это адрес внутренней сети, а не сервера. Вставь IP из письма хостера.")
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

// ipCheckReset — приложение закрыли: забыть адрес и недоделанную проверку (её итог уже никуда не попадёт).
func ipCheckReset() {
	ipc.mu.Lock()
	ipc.gen++
	ipc.res = IPCheck{}
	ipc.mu.Unlock()
}

// Итог стука с этого устройства.
const (
	selfOK      = "ok"      // пришло «SSH-…»
	selfSilent  = "silent"  // соединилось, но приветствие SSH не пришло
	selfRefused = "refused" // сервер ответил «порт закрыт»
	selfFail    = "fail"    // не достучались
)

// knockSelf: соединиться и дождаться строки «SSH-…». По правилам SSH перед ней сервер может прислать
// другие строки (приветствие, баннер) — их пропускаем. Читаем не больше 8 КБ и не дольше ipCheckBanner.
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
	r := bufio.NewReaderSize(io.LimitReader(c, 8192), 8192)
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return selfSilent // строка не дошла до конца — приветствия нет
		}
		if !strings.HasPrefix(line, "SSH-") {
			continue // баннер перед приветствием — пропускаем
		}
		id := strings.TrimRight(line, "\r\n")
		soft := strings.TrimPrefix(strings.TrimPrefix(id, "SSH-2.0-"), "SSH-1.99-")
		if len(line) <= 255 && soft != id && soft != "" && soft[0] != ' ' && !strings.ContainsRune(id, 0) {
			return selfOK
		}
		return selfSilent
	}
}

// ruResult: узлов в России выбрано (total), ответили «соединился» (ok), «порт закрыт» (refused),
// «не достучался» (fail). Кто не успел — ни в одной из трёх. total == 0 — узнать не вышло.
type ruResult struct{ ok, refused, fail, total int }

func (r ruResult) done() int { return r.ok + r.refused + r.fail }

var chClient = &http.Client{Timeout: 10 * time.Second}

var requestIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

func chGet(ctx context.Context, path string, out interface{}) error {
	req, err := http.NewRequestWithContext(ctx, "GET", checkHostURL+path, nil)
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
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	return json.Unmarshal(body, out)
}

func knockRussia(target string) ruResult {
	ctx, cancel := context.WithTimeout(context.Background(), ipCheckWait)
	defer cancel()
	var hosts struct {
		Nodes map[string]struct {
			Location []string `json:"location"`
		} `json:"nodes"`
	}
	if err := chGet(ctx, "/nodes/hosts", &hosts); err != nil {
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
	if err := chGet(ctx, "/check-tcp?"+q.Encode(), &start); err != nil || start.OK != 1 || !requestIDPattern.MatchString(start.RequestID) {
		return ruResult{}
	}
	// Узлы выбраны — total больше не меняется. Кто не ответил к концу — так и остаётся «не успел».
	res := ruResult{total: len(ru)}
	final := map[string]string{}
	for {
		select {
		case <-ctx.Done():
			return res
		case <-time.After(ipCheckPoll):
		}
		var out map[string]json.RawMessage
		if err := chGet(ctx, "/check-result/"+start.RequestID, &out); err != nil {
			continue
		}
		for _, n := range ru {
			if _, got := final[n]; got {
				continue
			}
			raw, ok := out[n]
			if !ok || string(raw) == "null" {
				continue // ещё думает
			}
			var items []map[string]interface{}
			if json.Unmarshal(raw, &items) != nil || len(items) == 0 {
				final[n] = "fail" // мусор вместо ответа — не «успех»
				continue
			}
			e, _ := items[0]["error"].(string)
			switch {
			case e == "" && items[0]["time"] != nil:
				final[n] = "ok"
			case strings.Contains(strings.ToLower(e), "refused"):
				final[n] = "refused"
			default:
				final[n] = "fail"
			}
		}
		res = ruResult{total: len(ru)}
		for _, st := range final {
			switch st {
			case "ok":
				res.ok++
			case "refused":
				res.refused++
			default:
				res.fail++
			}
		}
		if res.done() == res.total {
			return res
		}
	}
}

func runIPCheck(target string, ip net.IP, stage func(string)) IPCheck {
	var self string
	var ru ruResult
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); self = knockSelf(target) }()
	go func() { defer wg.Done(); ru = knockRussia(target) }()
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
		r.Self = "⚠️ С твоего интернета — соединилось, но сервер не ответил по SSH"
	case selfRefused:
		r.Self = "⚠️ С твоего интернета — сервер ответил «порт закрыт»"
	default:
		r.Self = "❌ С твоего интернета — не открывается"
	}
	pending := ru.total - ru.done()
	switch {
	case ru.total == 0:
		r.Russia = "check-host.net не ответил — узлы в России не проверены"
	case ru.ok == ru.total:
		r.Russia = fmt.Sprintf("✅ Узлы в России — открывается у всех (%d из %d)", ru.ok, ru.total)
	default:
		s := fmt.Sprintf("Узлы в России — открывается у %d из %d", ru.ok, ru.total)
		if ru.refused > 0 {
			s += fmt.Sprintf(", «порт закрыт» у %d", ru.refused)
		}
		if pending > 0 {
			s += fmt.Sprintf(", не успели ответить %d", pending)
		}
		if ru.ok == 0 && pending == 0 && ru.refused == 0 {
			r.Russia = "❌ " + s
		} else {
			r.Russia = "⚠️ " + s
		}
	}
	const bad = "Пиши в поддержку хостера: «Смените IP на не заблокированный в РФ, из другой подсети». " +
		"Не меняют — заявка на удаление и возврат денег, пока не вышел срок. На этот IP ничего не ставь."
	allOK := ru.total > 0 && ru.ok == ru.total
	anyFail := ru.fail > 0
	switch {
	case self == selfOK && allOK:
		r.Verdict, r.Title = "green", "Работает — пользуйся"
		r.Advice = "IP из России открывается везде, где проверил. Жми «Сервер есть →» и ставь Комбайн дальше по шагам."
	case self == selfOK && ru.ok > 0 && (anyFail || ru.refused > 0):
		r.Verdict, r.Title = "red", "Нестабильно — не бери"
		r.Advice = "У части провайдеров в России не открывается. Сегодня у одного, завтра у всех. " + bad
	case self == selfOK && !anyFail && ru.refused == 0:
		// Часть узлов не успела, ошибок нет — или check-host вообще молчит.
		r.Verdict, r.Title = "yellow", "Не проверить — узлы в России не ответили"
		r.Advice = "У тебя открывается, а check-host.net ответил не полностью. Проверь ещё раз через пару минут. Брать — только когда будет зелёное."
	case self == selfRefused && ru.total > 0 && ru.refused == ru.total:
		r.Verdict, r.Title = "yellow", "Не проверить — порт закрыт"
		r.Advice = "Сервер отвечает всем «порт закрыт» — SSH ещё не запустился или он на другом порту. " +
			"Подожди 5 минут и проверь ещё раз, или глянь порт в письме хостера и проверь так: IP:порт. Брать — только когда будет зелёное."
	case self == selfSilent:
		r.Verdict, r.Title = "red", "Не работает — сервер не отвечает по SSH"
		r.Advice = "Соединение есть, но SSH не ответил — так бывает, когда адрес режут. " + bad
	case self == selfOK:
		r.Verdict, r.Title = "red", "Не работает — из России не открывается"
		r.Advice = "У тебя открылось, а у узлов в России — нет. Если на этом устройстве или на роутере включён VPN — " +
			"проверка с твоей стороны соврала. " + bad
	case ru.ok > 0:
		r.Verdict, r.Title = "red", "Не работает у твоего провайдера"
		r.Advice = "У части провайдеров в России открывается, а у тебя — нет. " + bad
	default:
		r.Verdict, r.Title = "red", "Не работает — из России не открывается"
		r.Advice = "Только что купил? Подожди 5 минут и проверь ещё раз — сервер может ещё запускаться. Снова красное — значит, IP в бане. " + bad
	}
	return r
}
