#!/usr/bin/env python3
"""Комбайн: Telegram-бот — пульт управления сервером.

Бот ничего не настраивает сам: он вызывает те же команды, что и меню в терминале
(`kombain.sh cli <модуль> <команда>`). Отвечает только владельцу (ADMIN_ID).
Только стандартная библиотека Python.
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
ADMIN = int(os.environ["ADMIN_ID"])
KB_SRC = os.environ.get("KB_SRC", "/opt/kombain/src")
KB = os.path.join(KB_SRC, "kombain.sh")
LOG_DIR = "/opt/kombain/logs"
API = f"https://api.telegram.org/bot{TOKEN}"

B_AI, B_SERVER, B_HELP = "🧠 Нейронки", "📊 Сервер", "❓ Помощь"
MAIN_KB = {"keyboard": [[{"text": B_AI}], [{"text": B_SERVER}, {"text": B_HELP}]],
           "resize_keyboard": True, "is_persistent": True}

CLIENT_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
DOMAIN_RE = re.compile(r"^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$")

state = {}          # chat -> {"step": ..., ...} — пошаговая установка
busy = threading.Lock()   # одна долгая операция за раз


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
        # если HTML не разобрался — шлём простым текстом
        p.pop("parse_mode")
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


def btn(text, data):
    return {"text": text, "callback_data": data[:64]}


def inline(*rows):
    return {"inline_keyboard": [list(r) for r in rows]}


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


def aip_info():
    code, out = kb("aiproxy", "info", timeout=60)
    try:
        return json.loads(out.splitlines()[-1])
    except Exception:
        return {"installed": False, "error": out}


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


# ───────────────────────── Нейронки ─────────────────────────
AI_ABOUT = ("🧠 <b>Прокси для нейронок</b>\n\n"
            "ChatGPT, Gemini, Claude и Copilot откроются без VPN, просто через настройку DNS "
            "на телефоне или компе. Остальные сайты идут как обычно.\n\n"
            "Понадобится: домен и бесплатный аккаунт Cloudflare. Я проведу по шагам.")


def ai_screen(chat):
    info = aip_info()
    if not info.get("installed"):
        send(chat, AI_ABOUT, inline([btn("🚀 Установить", "aip:install")]))
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


def ai_install_start(chat):
    info = aip_info()
    if info.get("installed"):
        send(chat, "Уже стоит.")
        return
    ip = info.get("server_ip", "")
    state[chat] = {"step": "aip_domain", "ip": ip}
    _, txt = kb("aiproxy", "text-domain", timeout=30)
    send_pre(chat, txt, "<b>Шаг 1 из 4: домен</b>")
    send(chat, "Когда домен будет в Cloudflare — пришли его сюда одним сообщением.\n"
               "Например: <code>mojdns.site</code>", inline([btn("✖️ Отмена", "cancel")]))


def ai_got_domain(chat, text):
    d = text.strip().lower()
    d = re.sub(r"^https?://", "", d).split("/")[0].rstrip(".")
    d = re.sub(r"^dns\.", "", d)
    if not DOMAIN_RE.match(d):
        send(chat, "Это не похоже на домен. Пример: <code>mojdns.site</code>")
        return
    st = state[chat]
    st.update(step="aip_records", domain=d)
    _, txt = kb("aiproxy", "text-records", st["ip"], timeout=30)
    send_pre(chat, txt, "<b>Шаг 2 из 4: записи в Cloudflare</b>")
    send(chat, "Сделал записи — жми кнопку.",
         inline([btn("✅ Сделал, проверить", "aip:checkdns")], [btn("✖️ Отмена", "cancel")]))


def ai_check_dns(chat):
    st = state.get(chat)
    if not st or st.get("step") != "aip_records":
        send(chat, "Начни заново: 🧠 Нейронки → Установить.")
        return
    code, out = kb("aiproxy", "check-dns", st["domain"], st["ip"], timeout=60)
    if code != 0:
        send_pre(chat, out, "Пока не вижу записи.",
                 inline([btn("🔁 Проверить ещё раз", "aip:checkdns")], [btn("✖️ Отмена", "cancel")]))
        send(chat, "Если только что менял NS у регистратора — подожди 10–30 минут.")
        return
    st["step"] = "aip_token"
    _, txt = kb("aiproxy", "text-token", timeout=30)
    send_pre(chat, out)
    send_pre(chat, txt, "<b>Шаг 3 из 4: ключ Cloudflare</b>")
    send(chat, "Пришли ключ сообщением. Я его сразу удалю из чата.", inline([btn("✖️ Отмена", "cancel")]))


def ai_got_token(chat, text, msg_id):
    delete(chat, msg_id)
    token = text.strip()
    if len(token) < 30 or " " in token:
        send(chat, "Это не похоже на ключ Cloudflare. Скопируй его целиком и пришли ещё раз.")
        return
    st = state[chat]
    st.update(step="aip_client", token=token)
    send(chat, "🔐 Ключ получен и удалён из чата.\n\n<b>Шаг 4 из 4: первое устройство</b>\n"
               "Как назвать твой телефон? Латиницей, например <code>vasya-phone</code>.",
         inline([btn("Назвать phone", "aip:client:phone")], [btn("✖️ Отмена", "cancel")]))


def ai_got_client(chat, name):
    name = name.strip().lower()
    if not CLIENT_RE.match(name):
        send(chat, "Только маленькие латинские буквы, цифры и дефис. Например <code>vasya-phone</code>.")
        return
    st = state.pop(chat, None)
    if not st or "token" not in st:
        send(chat, "Начни заново: 🧠 Нейронки → Установить.")
        return

    def job():
        os.makedirs(LOG_DIR, exist_ok=True)
        code, out = kb("aiproxy", "install", timeout=1200, env={
            "KB_DOMAIN": st["domain"], "KB_CF_TOKEN": st["token"],
            "KB_CLIENT": name, "KB_SERVER_IP": st["ip"]})
        with open(os.path.join(LOG_DIR, "aiproxy-install.log"), "w") as f:
            f.write(out)
        if code != 0:
            send_pre(chat, "\n".join(out.splitlines()[-30:]), "❌ Установка не прошла. Последние строки:",
                     inline([btn("🚀 Попробовать снова", "aip:install")]))
            return
        send_pre(chat, "\n".join(out.splitlines()[-12:]), "✅ Готово!")
        _, how = kb("aiproxy", "howto", name, timeout=60)
        send_pre(chat, how, "📲 Как подключить")
        ai_screen(chat)

    run_long(chat, "Ставлю AdGuard и прокси. Это 2–5 минут, я напишу.", job)


def ai_pick_client(chat, prefix):
    clients = aip_info().get("clients") or []
    if not clients:
        send(chat, "Устройств нет. Добавь: ➕ Добавить устройство.")
        return
    rows = [[btn(c, f"{prefix}{c}")] for c in clients[:30]]
    send(chat, "Какое устройство?", {"inline_keyboard": rows})


def ai_callback(chat, data):
    if data == "aip:install":
        ai_install_start(chat)
    elif data == "aip:checkdns":
        ai_check_dns(chat)
    elif data.startswith("aip:client:"):
        ai_got_client(chat, data.split(":", 2)[2])
    elif data == "aip:add":
        state[chat] = {"step": "aip_add"}
        send(chat, "Как назвать новое устройство? Латиницей, например <code>mama-phone</code>.",
             inline([btn("✖️ Отмена", "cancel")]))
    elif data == "aip:howto":
        ai_pick_client(chat, "aip:how:")
    elif data == "aip:check":
        ai_pick_client(chat, "aip:chk:")
    elif data.startswith("aip:chk:"):
        _, out = kb("aiproxy", "check-client", data.split(":", 2)[2], timeout=60)
        send_pre(chat, out, "🔍 Проверка устройства")
    elif data.startswith("aip:how:"):
        _, out = kb("aiproxy", "howto", data.split(":", 2)[2], timeout=60)
        send_pre(chat, out, "📲 Как подключить")
    elif data == "aip:status":
        _, out = kb("aiproxy", "status", timeout=120)
        send_pre(chat, out, "📊 Состояние")
    elif data == "aip:logs":
        _, out = kb("aiproxy", "logs", timeout=60)
        send_pre(chat, out, "📜 Логи")
    elif data == "aip:upd":
        run_long(chat, "Обновляю список нейронок…",
                 lambda: send_pre(chat, kb("aiproxy", "update-domains")[1], "🔄 Готово"))
    elif data == "aip:restart":
        run_long(chat, "Перезапускаю…", lambda: send_pre(chat, kb("aiproxy", "restart")[1]))
    elif data == "aip:rm":
        send(chat, "🗑 Удалить прокси для нейронок? Все устройства перестанут работать.",
             inline([btn("Удалить, данные оставить", "aip:rm:keep")],
                    [btn("Удалить всё насовсем", "aip:rm:purge")],
                    [btn("✖️ Нет", "cancel")]))
    elif data in ("aip:rm:keep", "aip:rm:purge"):
        args = ["aiproxy", "remove"] + (["--purge"] if data.endswith("purge") else [])
        run_long(chat, "Удаляю…", lambda: send_pre(chat, kb(*args)[1], "🗑 Готово"))


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
        "🧠 <b>Нейронки</b> — ChatGPT, Gemini, Claude без VPN, через DNS. Установка, устройства, состояние.\n"
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
    if text == B_AI:
        state.pop(chat, None)
        ai_screen(chat)
        return
    if text == B_SERVER:
        server_screen(chat)
        return
    if text == B_HELP:
        send(chat, HELP, MAIN_KB)
        return

    st = state.get(chat, {}).get("step")
    if st == "aip_domain":
        ai_got_domain(chat, text)
    elif st == "aip_token":
        ai_got_token(chat, text, m["message_id"])
    elif st == "aip_client":
        ai_got_client(chat, text)
    elif st == "aip_add":
        name = text.strip().lower()
        if not CLIENT_RE.match(name):
            send(chat, "Только маленькие латинские буквы, цифры и дефис.")
            return
        state.pop(chat, None)
        code, out = kb("aiproxy", "add-client", name, timeout=60)
        if code != 0:
            send_pre(chat, out, "❌ Не добавилось")
            return
        _, how = kb("aiproxy", "howto", name, timeout=60)
        send_pre(chat, how, f"✅ Устройство {esc(name)} добавлено")
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
    elif data.startswith("aip:"):
        ai_callback(chat, data)


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
