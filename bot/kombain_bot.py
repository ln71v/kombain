#!/usr/bin/env python3
"""Комбайн: Telegram-бот — пульт управления сервером.

Бот ничего не настраивает сам: он вызывает те же команды, что и меню в терминале
(`kombain.sh cli <модуль> <команда>`). Отвечает только владельцу (ADMIN_ID).
Только стандартная библиотека Python.

Установка идёт в два этапа:
  1. Сбор — всё нужное складываем в «Сейф» (домен, записи, ключ, имя телефона).
     Сейф переживает что угодно: закрыл чат, вернулся завтра — всё на месте.
  2. Одна кнопка «Устанавливай» — и ждёшь.
"""
import json
import os
import re
import subprocess
import threading
import time
import traceback
import urllib.error
import urllib.request

TOKEN = os.environ["BOT_TOKEN"]
ADMIN = int(os.environ.get("ADMIN_ID") or 0)
CLAIM_CODE = os.environ.get("CLAIM_CODE", "").strip()
BOT_ENV = "/opt/kombain/bot/env"
claim_fails = {}         # кто сколько раз ошибся кодом
KB_SRC = os.environ.get("KB_SRC", "/opt/kombain/src")
KB = os.path.join(KB_SRC, "kombain.sh")
LOG_DIR = "/opt/kombain/logs"
API = f"https://api.telegram.org/bot{TOKEN}"

B_AI, B_SAFE, B_SERVER, B_HELP = "🧠 Нейронки", "🔐 Сейф", "📊 Сервер", "❓ Помощь"
MAIN_KB = {"keyboard": [[{"text": B_AI}, {"text": B_SAFE}], [{"text": B_SERVER}, {"text": B_HELP}]],
           "resize_keyboard": True, "is_persistent": True}

CLIENT_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")

state = {}               # chat -> {"step": ...} — чего ждём от пользователя
records_ok = {}          # домен -> True, когда записи в Cloudflare проверены
busy = threading.Lock()  # одна долгая операция за раз

SAFE_WARN = ("⚠️ Как только пришлёшь — я сразу удалю твоё сообщение из чата. "
             "Не пугайся, что оно пропало: так надо, чтобы ключ не висел в переписке. "
             "Он уже лежит в сейфе.")


# ───────────────────────── Telegram ─────────────────────────
def call(method, **params):
    req = urllib.request.Request(f"{API}/{method}", data=json.dumps(params).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=70) as r:
        return json.load(r)


def esc(t):
    return str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def send(chat, text, markup=None):
    p = {"chat_id": chat, "text": text[:4000], "parse_mode": "HTML", "disable_web_page_preview": True}
    if markup:
        p["reply_markup"] = markup
    try:
        return call("sendMessage", **p)
    except urllib.error.HTTPError:
        p.pop("parse_mode")   # если HTML не разобрался — простым текстом
        return call("sendMessage", **p)


def send_pre(chat, text, title="", markup=None):
    text = text.strip() or "(пусто)"
    if len(text) > 3500:
        text = "…\n" + text[-3500:]
    send(chat, (f"{title}\n" if title else "") + f"<pre>{esc(text)}</pre>", markup)


def delete(chat, msg_id):
    try:
        call("deleteMessage", chat_id=chat, message_id=msg_id)
    except Exception:
        pass


def last_line(out, default=""):
    """Последняя строка вывода без значков ✔ ✖ ! из терминала."""
    line = out.strip().splitlines()[-1] if out.strip() else default
    return line.lstrip("✔✖! ").strip()


def btn(text, data):
    return {"text": text, "callback_data": data[:64]}


def inline(*rows):
    return {"inline_keyboard": [list(r) for r in rows if r]}


CANCEL = [btn("✖️ Отмена", "cancel")]
TO_SAFE = [btn("🔐 Назад в сейф", "safe:open")]


# ───────────────────────── вызов Комбайна ─────────────────────────
def kb(*args, env=None, timeout=900):
    """Запустить `kombain.sh cli ...`. Вернуть (код, вывод)."""
    e = dict(os.environ)
    e.pop("BOT_TOKEN", None)
    if env:
        e.update(env)
    try:
        r = subprocess.run([KB, "cli", *args], capture_output=True, text=True, timeout=timeout, env=e,
                           stdin=subprocess.DEVNULL)
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "Команда не уложилась по времени."


def kb_json(*args):
    _, out = kb(*args, timeout=60)
    try:
        return json.loads(out.splitlines()[-1])
    except Exception:
        return {}


def kb_text(name, *args):
    """Текст подсказки из Комбайна — обычным сообщением, чтобы ссылки нажимались."""
    _, txt = kb("aiproxy", name, *args, timeout=30)
    return esc(txt)


def aip_info():
    return kb_json("aiproxy", "info")


def sec_info():
    return kb_json("secrets", "info")


def run_long(chat, title, func):
    """Долгая операция в фоне, чтобы бот не завис."""
    if not busy.acquire(blocking=False):
        send(chat, "⏳ Уже что-то делаю. Дождись конца.")
        return

    def work():
        try:
            func()
        except Exception:
            send_pre(chat, traceback.format_exc()[-1500:], "💥 Ошибка в боте")
        finally:
            busy.release()

    send(chat, f"⏳ {title}")
    threading.Thread(target=work, daemon=True).start()


# ───────────────────────── Сейф: место сбора ─────────────────────────
def check_records(domain, ip):
    if records_ok.get(domain):
        return True, ""
    code, out = kb("aiproxy", "check-dns", domain, ip, timeout=60)
    if code == 0:
        records_ok[domain] = True
    return code == 0, out


def safe_screen(chat):
    state.pop(chat, None)
    safe, info = sec_info(), aip_info()
    ip = info.get("server_ip", "")
    domain = safe.get("domain")
    rec = check_records(domain, ip)[0] if domain else False
    has_key, client = bool(safe.get("cloudflare")), safe.get("client")
    mark = lambda ok: "✅" if ok else "⬜"

    text = ("🔐 <b>Сейф — сюда собираем всё для установки</b>\n"
            "Сначала собираем по пунктам. Потом одна кнопка — и ждёшь.\n"
            "Закрыл чат, вернулся завтра — всё собранное на месте.\n\n"
            f"{mark(domain)} 1. Домен{': ' + esc(domain) if domain else ''}\n"
            f"{mark(rec)} 2. Две записи в Cloudflare{'' if domain else ' (сначала домен)'}\n"
            f"{mark(has_key)} 3. API-ключ Cloudflare{': ' + esc(safe['cloudflare']) if has_key else ''}\n"
            f"{mark(client)} 4. Имя твоего телефона{': ' + esc(client) if client else ''}\n")
    rows = []
    if not domain:
        rows += [[btn("1️⃣ Как купить домен", "safe:h:buy")], [btn("1️⃣ Положить домен", "safe:put:domain")]]
    if domain and not rec:
        rows += [[btn("2️⃣ Что сделать в Cloudflare", "safe:h:rec")], [btn("2️⃣ Проверить записи", "safe:chk")]]
    if not has_key:
        rows += [[btn("3️⃣ Где взять ключ", "safe:h:key")], [btn("3️⃣ Положить ключ", "safe:put:cf")]]
    if not client:
        rows += [[btn("4️⃣ Назвать phone", "safe:client:phone"), btn("4️⃣ Своё имя", "safe:put:client")]]

    ready = domain and rec and has_key and client
    if info.get("installed"):
        text += "\n🧠 Нейронки уже стоят."
    elif ready:
        text += "\n🎉 <b>Всё собрано!</b> Жми кнопку и жди."
        rows.insert(0, [btn("🚀 Всё собрано — устанавливай", "safe:go")])
    # заменить уже положенное
    swap = [b for ok, b in ((domain, btn("Сменить домен", "safe:put:domain")),
                            (has_key, btn("Сменить ключ", "safe:put:cf")),
                            (client, btn("Сменить имя", "safe:put:client"))) if ok]
    if swap:
        rows.append(swap)
    send(chat, text, {"inline_keyboard": rows} if rows else None)


def safe_help(chat, what):
    if what == "buy":
        send(chat, kb_text("text-buy"))
        send(chat, kb_text("text-cf"), inline([btn("✅ Купил, домен Active — положить", "safe:put:domain")], TO_SAFE))
    elif what == "rec":
        ip = aip_info().get("server_ip", "")
        send(chat, kb_text("text-records", ip), inline([btn("✅ Сделал — проверить", "safe:chk")], TO_SAFE))
    elif what == "key":
        send(chat, kb_text("text-token"), inline([btn("✅ Скопировал — положить", "safe:put:cf")], TO_SAFE))


PUT_ASK = {
    "domain": "Вставь сюда <b>свой домен</b>, например <code>mojdns.site</code>.",
    "cf": "Вставь сюда <b>API-ключ Cloudflare</b> — длинную строку после «Create Token» → «Copy».\n\n" + SAFE_WARN,
    "client": "Как назвать твой телефон? Латиницей, например <code>vasya-phone</code>.",
}


def safe_put_ask(chat, what):
    state[chat] = {"step": f"put_{what}"}
    send(chat, PUT_ASK[what], inline(CANCEL))


def safe_put(chat, what, text, msg_id):
    state.pop(chat, None)
    t = text.strip()
    if what == "cf":
        delete(chat, msg_id)
        code, out = kb("secrets", "set-cf", env={"KB_CF_TOKEN": t}, timeout=60)
        send(chat, "🔐 Сообщение удалила" + (", ключ проверен и лежит в сейфе." if code == 0 else "."))
    elif what == "domain":
        code, out = kb("secrets", "set-domain", t, timeout=30)
        records_ok.clear()
    else:
        code, out = kb("secrets", "set-client", t, timeout=30)
    if code != 0:
        send(chat, "❌ " + esc(last_line(out)), inline([btn("Попробовать ещё раз", f"safe:put:{what}")], TO_SAFE))
        return
    send(chat, "📦 " + esc(last_line(out)))
    safe_screen(chat)


def safe_check(chat):
    safe = sec_info()
    domain, ip = safe.get("domain"), aip_info().get("server_ip", "")
    if not domain:
        safe_screen(chat)
        return
    ok, out = check_records(domain, ip)
    if not ok:
        send_pre(chat, out, "Пока не вижу записи. Обычно появляются за 1–5 минут.",
                 inline([btn("🔁 Проверить ещё раз", "safe:chk")], [btn("Что сделать в Cloudflare", "safe:h:rec")],
                        TO_SAFE))
        return
    send(chat, "✅ Записи на месте.")
    safe_screen(chat)


def safe_go(chat):
    safe, info = sec_info(), aip_info()
    if info.get("installed"):
        send(chat, "Нейронки уже стоят.")
        return
    if not (safe.get("domain") and safe.get("cloudflare") and safe.get("client")):
        safe_screen(chat)
        return

    def job():
        os.makedirs(LOG_DIR, exist_ok=True)
        code, out = kb("aiproxy", "install", timeout=1200, env={"KB_SERVER_IP": info.get("server_ip", "")})
        with open(os.path.join(LOG_DIR, "aiproxy-install.log"), "w") as f:
            f.write(out)
        if code != 0:
            send_pre(chat, "\n".join(out.splitlines()[-30:]), "❌ Установка не прошла. Последние строки:",
                     inline([btn("🚀 Попробовать снова", "safe:go")], TO_SAFE))
            return
        send_pre(chat, "\n".join(out.splitlines()[-12:]), "✅ Готово, брат!")
        _, how = kb("aiproxy", "howto", safe["client"], timeout=60)
        send_pre(chat, how, "📲 Как подключить")
        ai_screen(chat)

    run_long(chat, "Ставлю. Жди, брат, 2–5 минут — я сам напишу. Можешь налить ещё.", job)


# ───────────────────────── Нейронки ─────────────────────────
AI_ABOUT = ("🧠 <b>Прокси для нейронок</b>\n\n"
            "ChatGPT, Gemini, Claude и Copilot откроются без VPN, просто через настройку DNS "
            "на телефоне или компе. Остальные сайты идут как обычно.")


def ai_screen(chat):
    info = aip_info()
    if not info.get("installed"):
        send(chat, AI_ABOUT)
        send(chat, kb_text("text-intro"), inline([btn("📋 Погнали собирать", "safe:open")]))
        return
    clients = info.get("clients") or []
    text = (f"🧠 <b>Прокси для нейронок</b> — стоит\n\n"
            f"Адрес: <code>{esc(info['dns_host'])}</code>\n"
            f"Устройства ({len(clients)}): {esc(', '.join(clients)) or 'нет'}")
    send(chat, text, inline(
        [btn("➕ Добавить устройство", "aip:add"), btn("📲 Как подключить", "aip:howto")],
        [btn("🔍 Проверить устройство", "aip:check")],
        [btn("📊 Состояние", "aip:status"), btn("📜 Логи", "aip:logs")],
        [btn("🔄 Обновить список нейронок", "aip:upd")],
        [btn("♻️ Перезапустить", "aip:restart"), btn("🗑 Удалить", "aip:rm")],
    ))


def ai_pick_client(chat, prefix):
    clients = aip_info().get("clients") or []
    if not clients:
        send(chat, "Устройств нет. Добавь: ➕ Добавить устройство.")
        return
    send(chat, "Какое устройство?", {"inline_keyboard": [[btn(c, f"{prefix}{c}")] for c in clients[:30]]})


def ai_add_client(chat, text):
    state.pop(chat, None)
    name = text.strip().lower()
    if not CLIENT_RE.match(name):
        send(chat, "Только маленькие латинские буквы, цифры и дефис.", inline([btn("Ещё раз", "aip:add")]))
        return
    code, out = kb("aiproxy", "add-client", name, timeout=60)
    if code != 0:
        send_pre(chat, out, "❌ Не добавилось")
        return
    _, how = kb("aiproxy", "howto", name, timeout=60)
    send_pre(chat, how, f"✅ Устройство {esc(name)} добавлено")


def ai_callback(chat, data):
    if data == "aip:add":
        state[chat] = {"step": "aip_add"}
        send(chat, "Как назвать новое устройство? Латиницей, например <code>mama-phone</code>.", inline(CANCEL))
    elif data == "aip:howto":
        ai_pick_client(chat, "aip:how:")
    elif data.startswith("aip:how:"):
        send_pre(chat, kb("aiproxy", "howto", data.split(":", 2)[2], timeout=60)[1], "📲 Как подключить")
    elif data == "aip:check":
        ai_pick_client(chat, "aip:chk:")
    elif data.startswith("aip:chk:"):
        send_pre(chat, kb("aiproxy", "check-client", data.split(":", 2)[2], timeout=60)[1], "🔍 Проверка устройства")
    elif data == "aip:status":
        send_pre(chat, kb("aiproxy", "status", timeout=120)[1], "📊 Состояние")
    elif data == "aip:logs":
        send_pre(chat, kb("aiproxy", "logs", timeout=60)[1], "📜 Логи")
    elif data == "aip:upd":
        run_long(chat, "Обновляю список нейронок…",
                 lambda: send_pre(chat, kb("aiproxy", "update-domains")[1], "🔄 Готово"))
    elif data == "aip:restart":
        run_long(chat, "Перезапускаю…", lambda: send_pre(chat, kb("aiproxy", "restart")[1]))
    elif data == "aip:rm":
        send(chat, "🗑 Удалить прокси для нейронок? Все устройства перестанут работать.",
             inline([btn("Удалить, данные оставить", "aip:rm:keep")],
                    [btn("Удалить всё насовсем", "aip:rm:purge")], CANCEL))
    elif data in ("aip:rm:keep", "aip:rm:purge"):
        args = ["aiproxy", "remove"] + (["--purge"] if data.endswith("purge") else [])
        run_long(chat, "Удаляю…", lambda: send_pre(chat, kb(*args)[1], "🗑 Готово"))


def safe_callback(chat, data):
    if data == "safe:open":
        safe_screen(chat)
    elif data.startswith("safe:h:"):
        safe_help(chat, data.split(":", 2)[2])
    elif data.startswith("safe:put:"):
        safe_put_ask(chat, data.split(":", 2)[2])
    elif data.startswith("safe:client:"):
        safe_put(chat, "client", data.split(":", 2)[2], None)
    elif data == "safe:chk":
        safe_check(chat)
    elif data == "safe:go":
        safe_go(chat)


# ───────────────────────── общие экраны ─────────────────────────
def server_screen(chat):
    cmd = ("echo \"IP: $(curl -4 -fs --max-time 5 https://api.ipify.org)\"; "
           "echo \"Работает: $(uptime -p)\"; "
           "free -h | awk '/Mem:/ {print \"Память: занято \" $3 \" из \" $2}'; "
           "df -h / | awk 'NR==2 {print \"Диск: занято \" $3 \" из \" $2 \" (\" $5 \")\"}'; "
           "echo; docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null")
    out = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=30).stdout
    send_pre(chat, out, "📊 <b>Сервер</b>")


HELP = ("🤖 <b>Пульт Комбайна</b>\n\n"
        "🧠 <b>Нейронки</b> — ChatGPT, Gemini, Claude без VPN, через DNS.\n"
        "🔐 <b>Сейф</b> — место сбора: сюда складываешь всё для установки, потом одна кнопка.\n"
        "📊 <b>Сервер</b> — IP, память, диск, что запущено.\n\n"
        "Скоро здесь же: VLESS, AmneziaWG, WARP, Telegram-прокси.\n\n"
        "Отменить любой шаг — /cancel.")


def on_message(m):
    chat = m["chat"]["id"]
    text = m.get("text") or ""
    if text in ("/start", "/menu"):
        state.pop(chat, None)
        send(chat, "Привет! Я пульт твоего сервера. Выбирай внизу 👇", MAIN_KB)
        return
    if text == "/cancel":
        state.pop(chat, None)
        send(chat, "Отменил.", MAIN_KB)
        return
    screens = {B_AI: ai_screen, B_SAFE: safe_screen, B_SERVER: server_screen,
               B_HELP: lambda c: send(c, HELP, MAIN_KB)}
    if text in screens:
        state.pop(chat, None)
        screens[text](chat)
        return

    step = state.get(chat, {}).get("step", "")
    if step.startswith("put_"):
        safe_put(chat, step[4:], text, m["message_id"])
    elif step == "aip_add":
        ai_add_client(chat, text)
    else:
        send(chat, "Выбирай кнопкой внизу 👇", MAIN_KB)


def on_callback(q):
    chat = q["message"]["chat"]["id"]
    data = q.get("data", "")
    try:
        call("answerCallbackQuery", callback_query_id=q["id"])
    except Exception:
        pass
    if data == "cancel":
        state.pop(chat, None)
        send(chat, "Отменил.", MAIN_KB)
    elif data.startswith("safe:"):
        safe_callback(chat, data)
    elif data.startswith("aip:"):
        ai_callback(chat, data)


def claim(m):
    """Хозяин ещё не привязан: ждём код из установщика. Кто прислал — тот хозяин."""
    global ADMIN
    uid, chat = m["from"]["id"], m["chat"]["id"]
    text = (m.get("text") or "").strip()
    if not CLAIM_CODE or claim_fails.get(uid, 0) >= 5 or sum(claim_fails.values()) >= 50:
        return
    if text == CLAIM_CODE:
        with open(BOT_ENV) as f:
            lines = f.read().splitlines()
        lines = [f"ADMIN_ID={uid}" if l.startswith("ADMIN_ID=") else
                 "CLAIM_CODE=" if l.startswith("CLAIM_CODE=") else l for l in lines]
        with open(BOT_ENV, "w") as f:
            f.write("\n".join(lines) + "\n")
        ADMIN = uid
        send(chat, "🤝 Есть! Теперь я слушаюсь только тебя.\n\n"
                   "Окно установщика на компе можно закрывать. Дальше всё здесь 👇", MAIN_KB)
        return
    if text.isdigit():
        claim_fails[uid] = claim_fails.get(uid, 0) + 1
        send(chat, "❌ Не тот код. Посмотри в окне установщика.")
    else:
        send(chat, "👋 Пришли код из окна установщика — 6 цифр.")


def main():
    offset = 0
    print("kombain bot started", flush=True)
    while True:
        try:
            r = call("getUpdates", offset=offset, timeout=50, allowed_updates=["message", "callback_query"])
        except Exception as e:
            print("getUpdates:", e, flush=True)
            time.sleep(5)
            continue
        for u in r.get("result", []):
            offset = u["update_id"] + 1
            src = u.get("message") or u.get("callback_query") or {}
            if not ADMIN:
                if "message" in u and u["message"].get("chat", {}).get("type") == "private":
                    try:
                        claim(u["message"])
                    except Exception:
                        traceback.print_exc()
                continue
            if (src.get("from") or {}).get("id") != ADMIN:
                continue   # чужим не отвечаем
            try:
                if "message" in u:
                    on_message(u["message"])
                elif "callback_query" in u:
                    on_callback(u["callback_query"])
            except Exception:
                traceback.print_exc()


if __name__ == "__main__":
    main()
