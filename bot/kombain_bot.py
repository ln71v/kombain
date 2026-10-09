#!/usr/bin/env python3
"""Комбайн: Telegram-бот — пульт управления сервером.

Бот ничего не настраивает сам: он вызывает те же команды, что и меню в терминале
(`kombain.sh cli <модуль> <команда>`). Отвечает только владельцу (ADMIN_ID).
Только стандартная библиотека Python.

Установка идёт в два этапа:
  1. Сбор — всё нужное складываем в «Сейф» (домен, ключ, название телефона).
     Записи в Cloudflare бот делает сам по ключу.
     Сейф переживает что угодно: можно закрыть чат и вернуться завтра.
  2. Одна кнопка «Устанавливай» — и ждёшь.
"""
import ipaddress
import json
import os
import re
import shlex
import shutil
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


def read_version():
    try:
        with open(os.path.join(KB_SRC, "VERSION")) as f:
            return "v" + f.read().strip()
    except OSError:
        return "v?"


VERSION = read_version()

B_AI, B_SAFE, B_SERVER, B_HELP = "🧠 Нейронки", "🔐 Сейф", "📊 Сервер", "❓ Помощь"
B_AWG, B_VLS, B_WARP, B_TGP = "🛡 AmneziaWG", "🔑 VLESS", "🌐 WARP", "✈️ Telegram"
MAIN_KB = {"keyboard": [[{"text": B_AI}, {"text": B_VLS}, {"text": B_AWG}],
                        [{"text": B_WARP}, {"text": B_SAFE}, {"text": B_SERVER}],
                        [{"text": B_TGP}, {"text": B_HELP}]],
           "resize_keyboard": True, "is_persistent": True}

CLIENT_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")

state = {}               # chat -> {"step": ...} — чего ждём от пользователя
records_ok = {}          # домен -> True, когда записи в Cloudflare проверены
busy = threading.Lock()  # одна долгая операция за раз

SAFE_WARN = ("⚠️ Как только сообщение придёт — я сразу удалю твоё сообщение из чата. "
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
    if TARGET:
        text = f"🎯 <b>{esc(TARGET['name'])}</b> · {TARGET['ip']}\n" + text
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


def send_file(chat, method, field, filename, data, caption="", ctype="application/octet-stream"):
    """Отправить файл (документ или картинку) — multipart вручную, только стандартная библиотека."""
    b = "kombain" + os.urandom(8).hex()
    parts = []
    for k, v in (("chat_id", str(chat)), ("caption", caption[:1000])):
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'
                 f"Content-Type: {ctype}\r\n\r\n".encode() + data + b"\r\n")
    parts.append(f"--{b}--\r\n".encode())
    req = urllib.request.Request(f"{API}/{method}", data=b"".join(parts),
                                 headers={"Content-Type": f"multipart/form-data; boundary={b}"})
    with urllib.request.urlopen(req, timeout=70) as r:
        return json.load(r)


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
    """Запустить `kombain.sh cli ...`. Вернуть (код, вывод).
    Выбран другой сервер (🗂 Мои серверы) — команда уходит туда по SSH."""
    if TARGET:
        return remote_kb(TARGET, args, env, timeout, text=True)
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


def kb_raw(*args, timeout=60):
    """То же, но вывод байтами (картинка QR)."""
    if TARGET:
        code, out = remote_kb(TARGET, args, None, timeout, text=False)
        return code, out
    try:
        r = subprocess.run([KB, "cli", *args], capture_output=True, timeout=timeout, stdin=subprocess.DEVNULL,
                           env={k: v for k, v in os.environ.items() if k != "BOT_TOKEN"})
        return r.returncode, r.stdout
    except subprocess.TimeoutExpired:
        return 124, b""


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


def make_records(chat, force=False):
    """Сами ставим записи в Cloudflare ключом из сейфа. True — записи на месте."""
    safe = sec_info()
    domain = safe.get("domain")
    if not (domain and safe.get("cloudflare")):
        return False
    ip = aip_info().get("server_ip", "")
    code, out = kb("aiproxy", "make-dns", *(["--force"] if force else []),
                   env={"KB_SERVER_IP": ip}, timeout=90)
    if code == 0:
        records_ok[domain] = True
        send_pre(chat, out, "🌐 Записи в Cloudflare сделала сама:")
        return True
    if code == 3:
        send_pre(chat, out, "⚠️ Эти имена в Cloudflare уже заняты другим адресом. "
                            f"Перезаписать на этот сервер ({esc(ip)})?",
                 inline([btn("✅ Да, перезаписать", "safe:mk:force")],
                        [btn("Сделаю руками", "safe:h:rec")], TO_SAFE))
        return False
    send_pre(chat, out, "❌ Записи сама сделать не смогла:",
             inline([btn("🔁 Попробовать ещё раз", "safe:mk")], [btn("Сделаю руками", "safe:h:rec")], TO_SAFE))
    return False


def safe_screen(chat):
    state.pop(chat, None)
    safe, info = sec_info(), aip_info()
    domain = safe.get("domain")
    rec = bool(records_ok.get(domain)) if domain else False
    has_key, client = bool(safe.get("cloudflare")), safe.get("client")
    mark = lambda ok: "✅" if ok else "⬜"

    text = ("🔐 <b>Сейф — сюда собираем всё для установки</b>\n"
            "Три пункта. Потом одна кнопка — и ждёшь.\n"
            "Можно закрыть чат и вернуться завтра — собранное никуда не денется.\n\n"
            f"{mark(domain)} 1. Домен{': ' + esc(domain) if domain else ''}\n"
            f"{mark(has_key)} 2. Ключ Cloudflare{': ' + esc(safe['cloudflare']) if has_key else ''}\n"
            f"{mark(client)} 3. Название телефона{': ' + esc(client) if client else ''}\n"
            f"{mark(rec)} Записи в Cloudflare — сделаю сама"
            f"{'' if domain and has_key else ' (нужны домен и ключ)'}\n")
    rows = []
    if not domain:
        rows += [[btn("1️⃣ Как купить домен", "safe:h:buy")], [btn("1️⃣ Положить домен", "safe:put:domain")]]
    if not has_key:
        rows += [[btn("2️⃣ Где взять ключ", "safe:h:key")], [btn("2️⃣ Положить ключ", "safe:put:cf")]]
    if not client:
        rows += [[btn("3️⃣ Назвать телефон", "safe:put:client")]]
    if domain and has_key and not rec:
        rows += [[btn("🌐 Сделать записи", "safe:mk")]]

    ready = domain and has_key and client
    if info.get("installed"):
        text += "\n🧠 Нейронки уже стоят."
    elif ready:
        text += ("\n🎉 <b>Всё собрано!</b> Для 🧠 Нейронок — кнопка ниже. "
                 "Для 🔑 VLESS со своим доменом — иди в 🔑 VLESS → «🌐 Свой домен».")
        rows.insert(0, [btn("🧠 Установить нейронки", "safe:go")])
    # заменить уже положенное
    swap = [b for ok, b in ((domain, btn("Сменить домен", "safe:put:domain")),
                            (has_key, btn("Сменить ключ", "safe:put:cf")),
                            (client, btn("Сменить название", "safe:put:client"))) if ok]
    if swap:
        rows.append(swap)
    send(chat, text, {"inline_keyboard": rows} if rows else None)


def safe_help(chat, what):
    if what == "buy":
        send(chat, kb_text("text-buy"))
        send(chat, kb_text("text-cf"), inline([btn("✅ Домен куплен и Active — положить", "safe:put:domain")], TO_SAFE))
    elif what == "rec":
        ip = aip_info().get("server_ip", "")
        send(chat, kb_text("text-records", ip), inline([btn("✅ Готово — проверить", "safe:chk")], TO_SAFE))
    elif what == "key":
        send(chat, kb_text("text-token"), inline([btn("✅ Ключ скопирован — положить", "safe:put:cf")], TO_SAFE))


PUT_ASK = {
    "domain": "Вставь сюда <b>свой домен</b>, например <code>mojdns.site</code>.",
    "cf": "Вставь сюда <b>API-ключ Cloudflare</b> — длинную строку после «Create Token» → «Copy».\n\n" + SAFE_WARN,
    "client": ("📱 <b>Как назвать телефон, с которого будешь заходить в нейронки?</b>\n\n"
               "Это просто подпись в списке устройств — чтобы потом отличать: "
               "вот мой телефон, вот ноут, вот мамин.\n"
               "Латиницей, без пробелов. Например <code>vasya-phone</code>.\n\n"
               "Лень думать — жми кнопку, назову просто <code>phone</code>."),
}


def safe_put_ask(chat, what):
    state[chat] = {"step": f"put_{what}"}
    extra = [btn("Назови просто phone", "safe:client:phone")] if what == "client" else None
    send(chat, PUT_ASK[what], inline(extra, CANCEL))


def safe_put(chat, what, text, msg_id):
    state.pop(chat, None)
    t = text.strip()
    if what == "cf":
        delete(chat, msg_id)
        code, out = kb("secrets", "set-cf", env={"KB_CF_TOKEN": t}, timeout=60)
        send(chat, "🔐 Сообщение удалено" + (", ключ проверен и лежит в сейфе." if code == 0 else "."))
    elif what == "domain":
        code, out = kb("secrets", "set-domain", t, timeout=30)
        records_ok.clear()
    else:
        code, out = kb("secrets", "set-client", t, timeout=30)
    if code != 0:
        send(chat, "❌ " + esc(last_line(out)), inline([btn("Попробовать ещё раз", f"safe:put:{what}")], TO_SAFE))
        return
    send(chat, "📦 " + esc(last_line(out)))
    if what in ("domain", "cf"):
        make_records(chat)
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
    if not records_ok.get(safe["domain"]) and not make_records(chat):
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
        send_pre(chat, "\n".join(out.splitlines()[-12:]), "✅ Готово!")
        _, how = kb("aiproxy", "howto", safe["client"], timeout=60)
        send_pre(chat, how, "📲 Как подключить")
        ai_screen(chat)

    run_long(chat, "Ставлю. Это 2–5 минут — напишу, как закончу. Можно пока налить чаю.", job)


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
    elif data == "safe:mk":
        make_records(chat) and safe_screen(chat)
    elif data == "safe:mk:force":
        make_records(chat, force=True) and safe_screen(chat)
    elif data == "safe:go":
        safe_go(chat)


# ───────────────────────── AmneziaWG ─────────────────────────
AWG_ABOUT = ("🛡 <b>AmneziaWG 3.1</b> — VPN для телефона и компа. Весь интернет идёт через сервер.\n\n"
             "Ставится без Docker, одной кнопкой. Для каждого устройства — свой файл и QR-код.\n"
             "Приложение: <b>Amnezia VPN</b> версии 5.0.1.5 или новее (Android, iPhone, Windows, Mac).")


def awg_screen(chat):
    info = kb_json("awg", "info")
    if not info.get("installed"):
        send(chat, AWG_ABOUT, inline([btn("🚀 Установить", "awg:install")]))
        return
    clients = info.get("clients") or []
    state_txt = "работает ✅" if info.get("running") else "не запущен ❌"
    send(chat, f"🛡 <b>AmneziaWG 3.1</b> — {state_txt}\n"
               f"Сервер: <code>{esc(info.get('endpoint', ''))}</code>\n"
               f"Устройства ({len(clients)}): {esc(', '.join(clients)) or 'нет'}",
         inline([btn("➕ Добавить устройство", "awg:add"), btn("📲 Ключ устройства", "awg:pick:show")],
                [btn("📊 Состояние", "awg:status"), btn("🗑 Удалить устройство", "awg:pick:rm")]))


def awg_send_client(chat, name):
    code, conf = kb("awg", "conf", name, timeout=30)
    if code != 0:
        send(chat, "❌ " + esc(last_line(conf)), awg_after())
        return
    qcode, png = kb_raw("awg", "qr-png", name)
    if qcode == 0 and png:
        send_file(chat, "sendPhoto", "photo", f"{name}.png", png,
                  f"QR для «{name}»: Amnezia VPN → «+» → «QR-код»", "image/png")
    send_file(chat, "sendDocument", "document", f"{name}.conf", conf.encode() + b"\n",
              "Или этот файл: Amnezia VPN → «+» → «Файл с настройками».\n"
              "Никому не пересылай — это ключ от твоего VPN.")
    send(chat, "Что дальше?", awg_after(name))


def awg_after(name=None):
    rows = []
    if name:
        rows.append([btn("🔁 Прислать ключ ещё раз", f"awg:show:{name}")])
    rows.append([btn("➕ Ещё устройство", "awg:add"), btn("◀️ Назад в AmneziaWG", "awg:menu")])
    return inline(*rows)


def awg_add(chat, text):
    state.pop(chat, None)
    name = text.strip().lower()
    if not CLIENT_RE.match(name):
        send(chat, "Только маленькие латинские буквы, цифры и дефис.", inline([btn("Ещё раз", "awg:add")]))
        return
    code, out = kb("awg", "add-client", name, timeout=60)
    if code != 0:
        send_pre(chat, out, "❌ Не добавилось",
                 inline([btn("🔁 Попробовать ещё раз", "awg:add")], [btn("◀️ Назад в AmneziaWG", "awg:menu")]))
        return
    awg_send_client(chat, name)


def awg_callback(chat, data):
    if data == "awg:install":
        def job():
            code, out = kb("awg", "install", timeout=1200,
                           env={"KB_SERVER_IP": aip_info().get("server_ip", "")})
            if code != 0:
                send_pre(chat, "\n".join(out.splitlines()[-25:]), "❌ Не встало. Последние строки:",
                         inline([btn("🚀 Попробовать снова", "awg:install")]))
                return
            send(chat, "✅ AmneziaWG работает. Теперь добавь устройство.",
                 inline([btn("➕ Добавить устройство", "awg:add")]))
        run_long(chat, "Ставлю AmneziaWG. Это 2–5 минут — собирается модуль ядра.", job)
    elif data == "awg:add":
        state[chat] = {"step": "awg_add"}
        send(chat, "📱 Как назвать устройство? Латиницей, например <code>vasya-phone</code>.\n"
                   "Это подпись в списке — чтобы отличать телефон, ноут, мамин.", inline(CANCEL))
    elif data == "awg:status":
        send_pre(chat, kb("awg", "status", timeout=60)[1], "📊 AmneziaWG", awg_after())
    elif data.startswith("awg:pick:"):
        what = data.split(":")[2]
        clients = kb_json("awg", "info").get("clients") or []
        if not clients:
            send(chat, "Устройств нет. Жми «➕ Добавить устройство».")
            return
        send(chat, "Какое устройство?", {"inline_keyboard": [[btn(c, f"awg:{what}:{c}")] for c in clients[:30]]})
    elif data.startswith("awg:show:"):
        awg_send_client(chat, data.split(":", 2)[2])
    elif data.startswith("awg:rm:"):
        name = data.split(":", 2)[2]
        send(chat, f"🗑 Удалить «{esc(name)}»? Этот ключ сразу перестанет работать.",
             inline([btn("Да, удалить", f"awg:rmok:{name}")], CANCEL))
    elif data.startswith("awg:rmok:"):
        send_pre(chat, kb("awg", "rm-client", data.split(":", 2)[2], timeout=60)[1], "🗑 Готово", awg_after())
    elif data == "awg:menu":
        awg_screen(chat)


# ───────────────────────── VLESS Reality ─────────────────────────
VLS_ABOUT = ("🔑 <b>VLESS Reality</b> — VPN, который снаружи выглядит как обычный заход на большой сайт.\n"
             "Режут его реже всего: работает и там, где AmneziaWG не пускают.\n\n"
             "Домен не нужен. Приложение: <b>Hiddify</b> или <b>Amnezia VPN</b>.\n"
             "Если в 🔐 Сейфе есть домен и ключ Cloudflare — сразу встанет на свой домен с сайтом-заглушкой.")

VLS_DOM_ABOUT = ("🌐 <b>Свой домен</b>\n\n"
                 "Сейчас без ключа сервер притворяется чужим сайтом ({sni}). "
                 "Со своим доменом он будет показывать твой собственный сайт-заглушку "
                 "с настоящим замком (сертификатом). Проверяющий увидит обычный сайт, адрес и сервер совпадают.\n\n"
                 "Домен: <code>{dom}</code> — запись в Cloudflare и сертификат сделаю сама.\n"
                 "⚠️ Ключи у всех устройств поменяются — QR придётся отсканировать заново.")


def vls_screen(chat):
    info = kb_json("vless", "info")
    if not info.get("installed"):
        send(chat, VLS_ABOUT, inline([btn("🚀 Установить", "vls:install")]))
        return
    clients = info.get("clients") or []
    state_txt = "работает ✅" if info.get("running") else "не запущен ❌"
    dom = info.get("domain") or ""
    mask = f"свой домен {esc(dom)}" if dom else f"маска {esc(info.get('sni', ''))}"
    send(chat, f"🔑 <b>VLESS Reality</b> — {state_txt}\n"
               f"Сервер: <code>{esc(info.get('endpoint', ''))}:443</code>, {mask}\n"
               f"Устройства ({len(clients)}): {esc(', '.join(clients)) or 'нет'}",
         inline([btn("➕ Добавить устройство", "vls:add"), btn("📲 Ключ устройства", "vls:pick:show")],
                [btn("📊 Состояние", "vls:status"), btn("🗑 Удалить устройство", "vls:pick:rm")],
                [btn("↩️ Вернуть чужую маску", "vls:domoff") if dom else btn("🌐 Свой домен", "vls:dom")]))


def vls_after_switch(chat, out, ok_title):
    """После смены маски: у всех устройств новый ключ — кнопки, чтобы прислать каждому."""
    clients = kb_json("vless", "info").get("clients") or []
    rows = [[btn(f"📲 {c}", f"vls:show:{c}")] for c in clients[:30]]
    rows.append([btn("◀️ Назад в VLESS", "vls:menu")])
    send_pre(chat, "\n".join(out.splitlines()[-12:]),
             ok_title + "\nКлючи поменялись — пришли каждое устройство заново и отсканируй QR:",
             {"inline_keyboard": rows})


def vls_send_client(chat, name):
    code, link = kb("vless", "link", name, timeout=30)
    if code != 0:
        send(chat, "❌ " + esc(last_line(link)), vls_after())
        return
    qcode, png = kb_raw("vless", "qr-png", name)
    if qcode == 0 and png:
        send_file(chat, "sendPhoto", "photo", f"{name}.png", png,
                  f"QR для «{name}»: Hiddify / Amnezia VPN → «+» → сканировать", "image/png")
    send(chat, f"Или скопируй ключ и вставь в приложение («+» → из буфера):\n<code>{esc(link.strip())}</code>\n\n"
               "Никому не пересылай — это ключ от твоего VPN.", vls_after(name))


def vls_after(name=None):
    """Кнопки после любого действия: что дальше, без прокрутки вверх."""
    rows = []
    if name:
        rows.append([btn("🔁 Прислать ключ ещё раз", f"vls:show:{name}")])
    rows.append([btn("➕ Ещё устройство", "vls:add"), btn("◀️ Назад в VLESS", "vls:menu")])
    return inline(*rows)


def vls_add(chat, text):
    state.pop(chat, None)
    name = text.strip().lower()
    if not CLIENT_RE.match(name):
        send(chat, "Только маленькие латинские буквы, цифры и дефис.", inline([btn("Ещё раз", "vls:add")]))
        return
    code, out = kb("vless", "add-client", name, timeout=60)
    if code != 0:
        send_pre(chat, out, "❌ Не добавилось",
                 inline([btn("🔁 Попробовать ещё раз", "vls:add")], [btn("◀️ Назад в VLESS", "vls:menu")]))
        return
    vls_send_client(chat, name)


def vls_callback(chat, data):
    if data == "vls:install":
        def job():
            code, out = kb("vless", "install", timeout=600,
                           env={"KB_SERVER_IP": aip_info().get("server_ip", "")})
            if code != 0:
                send_pre(chat, "\n".join(out.splitlines()[-25:]), "❌ Не встало. Последние строки:",
                         inline([btn("🚀 Попробовать снова", "vls:install")]))
                return
            send(chat, "✅ VLESS работает. Теперь добавь устройство.", inline([btn("➕ Добавить устройство", "vls:add")]))
        run_long(chat, "Ставлю VLESS. Это минута.", job)
    elif data == "vls:add":
        state[chat] = {"step": "vls_add"}
        send(chat, "📱 Как назвать устройство? Латиницей, например <code>vasya-phone</code>.\n"
                   "Это подпись в списке — чтобы отличать телефон, ноут, мамин.", inline(CANCEL))
    elif data == "vls:status":
        send_pre(chat, kb("vless", "status", timeout=60)[1], "📊 VLESS", vls_after())
    elif data.startswith("vls:pick:"):
        what = data.split(":")[2]
        clients = kb_json("vless", "info").get("clients") or []
        if not clients:
            send(chat, "Устройств нет. Жми «➕ Добавить устройство».")
            return
        send(chat, "Какое устройство?", {"inline_keyboard": [[btn(c, f"vls:{what}:{c}")] for c in clients[:30]]})
    elif data.startswith("vls:show:"):
        vls_send_client(chat, data.split(":", 2)[2])
    elif data.startswith("vls:rm:"):
        name = data.split(":", 2)[2]
        send(chat, f"🗑 Удалить «{esc(name)}»? Этот ключ сразу перестанет работать.",
             inline([btn("Да, удалить", f"vls:rmok:{name}")], CANCEL))
    elif data.startswith("vls:rmok:"):
        send_pre(chat, kb("vless", "rm-client", data.split(":", 2)[2], timeout=60)[1], "🗑 Готово", vls_after())
    elif data == "vls:menu":
        vls_screen(chat)
    elif data == "vls:dom":
        safe = sec_info()
        if not (safe.get("domain") and safe.get("cloudflare")):
            send(chat, "🌐 Для своего домена нужны <b>домен</b> и <b>ключ Cloudflare</b> в 🔐 Сейфе. "
                       "Заполни их и возвращайся сюда.",
                 inline([btn("🔐 Открыть сейф", "safe:open")], [btn("◀️ Назад в VLESS", "vls:menu")]))
            return
        info = kb_json("vless", "info")
        send(chat, VLS_DOM_ABOUT.format(sni=esc(info.get("sni", "")), dom=esc(safe["domain"])),
             inline([btn("✅ Переключить", "vls:domok")], [btn("◀️ Назад в VLESS", "vls:menu")]))
    elif data == "vls:domok":
        def job():
            code, out = kb("vless", "domain-on", timeout=600)
            if code != 0:
                send_pre(chat, "\n".join(out.splitlines()[-20:]), "❌ Не переключилось, VLESS работает как раньше:",
                         inline([btn("🔁 Попробовать ещё раз", "vls:domok")], [btn("◀️ Назад в VLESS", "vls:menu")]))
                return
            vls_after_switch(chat, out, "✅ VLESS на своём домене.")
        run_long(chat, "Делаю запись, сертификат и сайт. Пара минут.", job)
    elif data == "vls:domoff":
        send(chat, "↩️ Вернуть маску www.yahoo.com? Сайт-заглушка выключится.\n"
                   "⚠️ Ключи у всех устройств поменяются.",
             inline([btn("Да, вернуть", "vls:domoffok")], [btn("◀️ Назад в VLESS", "vls:menu")]))
    elif data == "vls:domoffok":
        code, out = kb("vless", "domain-off", timeout=120)
        if code != 0:
            send_pre(chat, out, "❌ Не получилось:", vls_after())
            return
        vls_after_switch(chat, out, "✅ Вернула маску.")


# ───────────────────────── общие экраны ─────────────────────────
def server_screen(chat):
    cmd = ("echo \"IP: $(curl -4 -fs --max-time 5 https://api.ipify.org)\"; "
           "echo \"Работает: $(uptime -p)\"; "
           "free -h | awk '/Mem:/ {print \"Память: занято \" $3 \" из \" $2}'; "
           "df -h / | awk 'NR==2 {print \"Диск: занято \" $3 \" из \" $2 \" (\" $5 \")\"}'; "
           "echo; docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null")
    n = len(srv_load())
    if TARGET:
        try:
            out = subprocess.run(ssh_base(TARGET) + [cmd], capture_output=True, text=True, timeout=40,
                                 stdin=subprocess.DEVNULL).stdout
        except subprocess.TimeoutExpired:
            out = "Сервер не ответил за 40 секунд."
        send_pre(chat, out, "📊 <b>Сервер</b>",
                 inline([btn("🔄 Обновить Комбайн там", f"srv:upd:{TARGET['ip']}")],
                        [btn(f"🗂 Мои серверы ({n})", "srv:list"), btn("🏠 К стенду", "srv:local")]))
        return
    out = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=30).stdout
    send_pre(chat, out, f"📊 <b>Сервер</b> · Комбайн {VERSION}",
             inline([btn("🔄 Обновить Комбайн", "upd:ask")],
                    [btn("➕ Новый сервер — проверить", "probe:ask")],
                    [btn(f"🗂 Мои серверы ({n})", "srv:list")]))


# ───────────────────────── Проверка нового сервера ─────────────────────────
# Купил сервер → IP и пароль → бот заходит туда по SSH, гоняет lib/probe-remote.sh и пишет отчёт.
# Пароль не сохраняется. На проверяемый сервер ничего не ставится (кроме curl, если его нет).
PROBE_SCRIPT = os.path.join(KB_SRC, "lib", "probe-remote.sh")
PROBE_BAD = {   # сети, которые сразу в мусор
    "AS215540": "в этой сети выходные узлы Tor и прокси-сервисы — нейронки такие адреса режут",
    "AS210644": "Aeza — под санкциями США, нейронки режут",
    "AS216246": "Aeza — под санкциями США, нейронки режут",
    "AS211522": "сеть, куда переехала Aeza после санкций",
}
PROBE_WARN = {  # не мусор, но знать надо
    "AS57043": "HOSTKEY — та же сеть, что у AdminVPS (Италия, Нидерланды). Нейронки пускает, "
               "но запасным к серверам AdminVPS не годится: забанят сеть — лягут оба.",
}
YES_NO = {"yes": "✅", "no": "❌"}


def probe_ask(chat):
    state[chat] = {"step": "probe_host"}
    send(chat, "➕ <b>Новый сервер — проверка</b>\n\n"
               "Купил сервер? Пришли его <b>IP</b> (если хостер дал другой порт — <code>IP:порт</code>).\n"
               "Проверю: чья сеть, кем его видит Google, пускают ли ChatGPT, Claude и Gemini.\n"
               "На сервер ничего не ставлю.", inline(CANCEL))


def probe_host(chat, text):
    t = text.strip()
    host, port = t, "22"
    if t.count(":") == 1:
        host, port = t.split(":")
    try:
        ipaddress.ip_address(host)
        if not port.isdigit() or not 0 < int(port) < 65536:
            raise ValueError
    except ValueError:
        send(chat, "Это не IP. Пример: <code>203.0.113.10</code> или <code>203.0.113.10:49222</code>",
             inline(CANCEL))
        return
    state[chat] = {"step": "probe_pass", "host": host, "port": port}
    send(chat, f"🔑 Пароль <b>root</b> от <code>{host}</code> — тот, что прислал хостер.\n\n"
               "⚠️ Как только придёт — удалю твоё сообщение из чата. Пароль нигде не сохраняю, "
               "он нужен один раз, чтобы зайти.", inline(CANCEL))


def probe_pass(chat, text, msg_id):
    delete(chat, msg_id)
    st = state.pop(chat, {})
    host, port, password = st.get("host"), st.get("port", "22"), text.strip()
    if not host or not password:
        send(chat, "Начни заново.", inline([btn("➕ Новый сервер", "probe:ask")]))
        return

    def job():
        ok, report = probe_run(host, port, password)
        rows = [[btn("🔁 Проверить ещё раз", "probe:ask")], [btn("🏠 Меню", "home")]]
        if ok:
            PW_CACHE[host] = (password, port, time.time())
            rows.insert(0, [btn("💾 Оставить сервер у бота", f"srv:save:{host}")])
        send(chat, report, inline(*rows))

    send(chat, "🔐 Сообщение с паролем удалено.")
    run_long(chat, f"Захожу на {host} и проверяю. До двух минут…", job)


def probe_run(host, port, password):
    if not shutil.which("sshpass"):
        subprocess.run(["apt-get", "install", "-y", "-qq", "sshpass"], capture_output=True, timeout=300,
                       env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"})
        if not shutil.which("sshpass"):
            subprocess.run(["apt-get", "update", "-qq"], capture_output=True, timeout=300)
            subprocess.run(["apt-get", "install", "-y", "-qq", "sshpass"], capture_output=True, timeout=300,
                           env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"})
    if not shutil.which("sshpass"):
        return False, "❌ Не смогла поставить sshpass на этот сервер — без него не зайти по паролю."
    with open(PROBE_SCRIPT) as f:
        script = f.read()
    r = pw_ssh(host, port, password, "bash -s", script, 240)
    if r is None:
        return False, f"❌ <code>{host}</code>: проверка не уложилась в 4 минуты. Связь плохая или сервер висит."
    if r.returncode == 5:
        return False, f"❌ <code>{host}</code>: неверный пароль. Скопируй его у хостера ещё раз."
    return probe_parse(host, port, r)


def probe_parse(host, port, r):
    if "PROBE_BEGIN" not in r.stdout:
        why = esc((r.stderr or r.stdout).strip()[-300:]) or "без объяснений"
        return False, (f"❌ Не зашла на <code>{host}</code>:{port}.\n<pre>{why}</pre>\n"
                       "Проверь IP и порт. Сервер мог ещё не подняться — подожди пару минут.")
    d = {}
    for line in r.stdout.split("PROBE_BEGIN", 1)[1].split("PROBE_END", 1)[0].splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            if v.strip():
                d[k.strip()] = v.strip()
    PROBE_INFO[host] = d
    return True, probe_report(host, d)


def pw_ssh(host, port, password, remote_cmd, stdin_text="", timeout=120):
    """Зайти по паролю (sshpass), выполнить команду. None — не уложились по времени."""
    env = {k: v for k, v in os.environ.items() if k != "BOT_TOKEN"}
    env["SSHPASS"] = password
    cmd = ["sshpass", "-e", "ssh", "-p", str(port),
           "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
           "-o", "ConnectTimeout=20", "-o", "PubkeyAuthentication=no",
           "-o", "PreferredAuthentications=password,keyboard-interactive",
           "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
           f"root@{host}", remote_cmd]
    try:
        return subprocess.run(cmd, input=stdin_text, capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return None
    finally:
        env.pop("SSHPASS", None)


# ───────────────────────── Мои серверы (режим админа) ─────────────────────────
# Сервер, оставленный после проверки: бот кладёт туда свой ключ и дальше ходит без пароля.
# Выбрал сервер — все кнопки внизу (VLESS, AmneziaWG, WARP, Telegram…) работают с ним.
ADMIN_DIR = "/opt/kombain/bot"
ADMIN_KEY = os.path.join(ADMIN_DIR, "admin_key")
SERVERS_FILE = os.path.join(ADMIN_DIR, "servers.json")
KNOWN_HOSTS = os.path.join(ADMIN_DIR, "known_hosts")
TARGET = None        # выбранный сервер (dict) или None — этот сервер
PW_CACHE = {}        # ip -> (пароль, порт, время) — только в памяти, 15 минут после проверки
PROBE_INFO = {}      # ip -> данные последней проверки
PW_TTL = 15 * 60
REMOTE_BOOT = ("command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl >/dev/null; }; "
               "[ -f /opt/kombain/src/lib/common.sh ] || { curl -fsSL "
               "https://raw.githubusercontent.com/ln71v/kombain/main/kombain.sh -o /tmp/kombain-start.sh "
               "&& bash /tmp/kombain-start.sh cli secrets info >/dev/null 2>&1; }; ")


def srv_load():
    try:
        with open(SERVERS_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def srv_store(lst):
    os.makedirs(ADMIN_DIR, exist_ok=True)
    tmp = SERVERS_FILE + ".new"
    with open(tmp, "w") as f:
        json.dump(lst, f, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, SERVERS_FILE)


def srv_get(ip):
    return next((x for x in srv_load() if x["ip"] == ip), None)


def ssh_base(srv):
    return ["ssh", "-i", ADMIN_KEY, "-p", str(srv.get("port", "22")),
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
            "-o", f"UserKnownHostsFile={KNOWN_HOSTS}", "-o", "ConnectTimeout=20",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "LogLevel=ERROR",
            f"root@{srv['ip']}"]


def remote_kb(srv, args, env, timeout, text=True):
    envs = " ".join(shlex.quote(f"{k}={v}") for k, v in (env or {}).items())
    cmd = REMOTE_BOOT + (f"env {envs} " if envs else "") + "/opt/kombain/src/kombain.sh cli " + \
        " ".join(shlex.quote(str(a)) for a in args)
    try:
        r = subprocess.run(ssh_base(srv) + [cmd], capture_output=True, text=text, timeout=timeout,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return 124, ("Команда не уложилась по времени." if text else b"")
    if not text:
        return r.returncode, r.stdout
    out = (r.stdout + r.stderr).strip()
    if r.returncode == 255 and not r.stdout:
        out = f"Не достучалась до {srv['ip']} по ключу: {out[-200:]}"
    return r.returncode, out


def ensure_key():
    if not os.path.exists(ADMIN_KEY):
        os.makedirs(ADMIN_DIR, exist_ok=True)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "kombain-admin",
                        "-f", ADMIN_KEY], capture_output=True, timeout=60)
    with open(ADMIN_KEY + ".pub") as f:
        return f.read().strip()


def srv_save_ask(chat, ip):
    if srv_get(ip):
        srv_open(chat, ip)
        return
    pw = PW_CACHE.get(ip)
    if pw and time.time() - pw[2] < PW_TTL:
        srv_save_run(chat, ip, pw[1], pw[0])
        return
    PW_CACHE.pop(ip, None)
    state[chat] = {"step": "srv_pass", "host": ip, "port": (pw or (None, "22"))[1]}
    send(chat, f"🔑 Пароль root от <code>{ip}</code> ещё раз — прошло больше 15 минут, я его уже забыла.\n"
               "Сообщение сразу удалю.", inline(CANCEL))


def srv_pass(chat, text, msg_id):
    delete(chat, msg_id)
    st = state.pop(chat, {})
    if st.get("host"):
        srv_save_run(chat, st["host"], st.get("port", "22"), text.strip())


def srv_save_run(chat, ip, port, password):
    def job():
        pub = ensure_key()
        q = shlex.quote(pub)
        r = pw_ssh(ip, port, password,
                   "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && "
                   f"(grep -qxF {q} ~/.ssh/authorized_keys || echo {q} >> ~/.ssh/authorized_keys) && echo KEY_OK", "", 60)
        PW_CACHE.pop(ip, None)
        if r is None or "KEY_OK" not in r.stdout:
            why = "неверный пароль" if r is not None and r.returncode == 5 else "не зашла"
            send(chat, f"❌ Не смогла оставить <code>{ip}</code>: {why}.",
                 inline([btn("🔁 Ещё раз", f"srv:save:{ip}")], [btn("🏠 Меню", "home")]))
            return
        d = PROBE_INFO.get(ip, {})
        name = " ".join(x for x in (d.get("COUNTRY"), d.get("CITY")) if x) or ip
        srv = {"ip": ip, "port": str(port), "name": name, "added": time.strftime("%Y-%m-%d")}
        t = subprocess.run(ssh_base(srv) + ["echo OK"], capture_output=True, text=True, timeout=40,
                           stdin=subprocess.DEVNULL)
        if "OK" not in t.stdout:
            send(chat, f"❌ Ключ положила, но зайти по нему не вышло:\n<pre>{esc(t.stderr[-300:])}</pre>")
            return
        lst = [x for x in srv_load() if x["ip"] != ip] + [srv]
        srv_store(lst)
        send(chat, f"💾 Оставила: <b>{esc(name)}</b> · <code>{ip}</code>.\n"
                   "Дальше хожу туда по своему ключу — пароль больше не нужен и нигде не лежит.")
        srv_open(chat, ip)
    run_long(chat, f"Кладу свой ключ на {ip}…", job)


def srv_list(chat):
    lst = srv_load()
    rows = [[btn(("✅ " if TARGET and TARGET["ip"] == x["ip"] else "🖥 ") + f"{x['name']} · {x['ip']}",
                 f"srv:open:{x['ip']}")] for x in lst]
    rows.append([btn(("✅ " if not TARGET else "🏠 ") + "Этот сервер (где живёт бот)", "srv:local")])
    rows.append([btn("➕ Новый сервер — проверить", "probe:ask")])
    head = "🗂 <b>Мои серверы</b>\n\n"
    head += ("Пока пусто. Проверь новый сервер и нажми «💾 Оставить сервер у бота»." if not lst else
             "Выбери сервер — и все кнопки внизу (VLESS, AmneziaWG, WARP, Telegram) будут работать с ним.")
    send(chat, head, inline(*rows))


def srv_open(chat, ip):
    global TARGET
    srv = srv_get(ip)
    if not srv:
        send(chat, "Такого сервера в списке нет.", inline([btn("🗂 Мои серверы", "srv:list")]))
        return
    TARGET = srv
    send(chat, "Теперь кнопки внизу — 🔑 VLESS, 🛡 AmneziaWG, 🌐 WARP, ✈️ Telegram, 📊 Сервер — работают "
               "<b>с этим сервером</b>. Сверху каждого сообщения будет 🎯 с его именем.\n\n"
               "Первый раз Комбайн там поставится сам — первая кнопка займёт минуту-две.",
         inline([btn("🔍 Проверить снова", f"srv:probe:{ip}"), btn("🔄 Обновить Комбайн там", f"srv:upd:{ip}")],
                [btn("🗑 Убрать сервер", f"srv:del:{ip}")],
                [btn("🏠 Вернуться к своему серверу", "srv:local")]))


def srv_local(chat):
    global TARGET
    TARGET = None
    send(chat, "🏠 Снова работаю со своим сервером (где живёт бот).", MAIN_KB)


def srv_probe(chat, ip):
    srv = srv_get(ip)
    if not srv:
        return

    def job():
        with open(PROBE_SCRIPT) as f:
            script = f.read()
        try:
            r = subprocess.run(ssh_base(srv) + ["bash -s"], input=script, capture_output=True, text=True,
                               timeout=240)
        except subprocess.TimeoutExpired:
            send(chat, "❌ Проверка не уложилась в 4 минуты.")
            return
        send(chat, probe_parse(ip, srv["port"], r)[1])
    run_long(chat, f"Проверяю {ip}…", job)


def srv_upd(chat, ip):
    srv = srv_get(ip)
    if not srv:
        return

    def job():
        try:
            r = subprocess.run(ssh_base(srv) + [REMOTE_BOOT + "/opt/kombain/src/kombain.sh --update cli secrets info "
                                                ">/dev/null && cat /opt/kombain/src/VERSION"],
                               capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
            out = r.stdout.strip().splitlines()[-1:] or ["?"]
            send(chat, f"✅ Комбайн на <code>{ip}</code>: версия <b>{esc(out[0])}</b>." if r.returncode == 0 else
                 f"❌ Не обновилось:\n<pre>{esc((r.stderr or r.stdout)[-400:])}</pre>")
        except subprocess.TimeoutExpired:
            send(chat, "❌ Не уложилось в 5 минут.")
    run_long(chat, f"Обновляю Комбайн на {ip}…", job)


def srv_del(chat, ip, sure=False):
    global TARGET
    srv = srv_get(ip)
    if not srv:
        return
    if not sure:
        send(chat, f"🗑 Убрать <b>{esc(srv['name'])}</b> · <code>{ip}</code> из списка?\n\n"
                   "Сотру свой ключ с того сервера и забуду его. Что там уже стоит (VPN, ключи) — "
                   "не трогаю, оно продолжит работать. Сам сервер удаляй у хостера.",
             inline([btn("🗑 Да, убрать", f"srv:delok:{ip}")], CANCEL))
        return

    def job():
        global TARGET
        pub = ensure_key().split()[1]
        try:
            r = subprocess.run(ssh_base(srv) + [f"sed -i '\\#{pub}#d' ~/.ssh/authorized_keys && echo DEL_OK"],
                               capture_output=True, text=True, timeout=40, stdin=subprocess.DEVNULL)
            gone = "DEL_OK" in r.stdout
        except subprocess.TimeoutExpired:
            gone = False
        srv_store([x for x in srv_load() if x["ip"] != ip])
        if TARGET and TARGET["ip"] == ip:
            TARGET = None
        send(chat, ("✅ Ключ стёрла, сервер забыла." if gone else
                    "⚠️ Сервер забыла, но стереть ключ не вышло (сервер не ответил). Если он ещё жив — "
                    "убери строку kombain-admin из /root/.ssh/authorized_keys руками."), MAIN_KB)
    run_long(chat, f"Убираю {ip}…", job)


def srv_callback(chat, data):
    parts = data.split(":", 2)
    act, arg = parts[1], (parts[2] if len(parts) > 2 else "")
    if act == "list":
        srv_list(chat)
    elif act == "local":
        srv_local(chat)
    elif act == "save":
        srv_save_ask(chat, arg)
    elif act == "open":
        srv_open(chat, arg)
    elif act == "probe":
        srv_probe(chat, arg)
    elif act == "upd":
        srv_upd(chat, arg)
    elif act == "del":
        srv_del(chat, arg)
    elif act == "delok":
        srv_del(chat, arg, sure=True)


def probe_report(host, d):
    org = d.get("ORG", "")
    asn = org.split()[0] if org.startswith("AS") else ""
    gl, country = d.get("GL", "?"), d.get("COUNTRY", "?")
    ram = d.get("RAM_MB", "")
    ram = f"{int(ram) / 1024:.1f} ГБ" if ram.isdigit() else "?"
    ai = {k: d.get(k.upper(), "?") for k in ("ChatGPT", "Claude", "Gemini")}
    lines = [f"🔍 <b>Новый сервер</b> <code>{esc(d.get('IP') or host)}</code>", "",
             f"🏢 Сеть (AS): <b>{esc(org or '?')}</b>"]
    reg = " · ".join(x for x in (d.get("REG_OWNER"), d.get("REG_NET")) if x)
    if reg:
        lines.append(f"📄 Кто выдал IP (реестр): <b>{esc(reg)}</b>")
    if d.get("IPAPI_ISP"):
        isp = d["IPAPI_ISP"] + (f" / {d['IPAPI_ORG']}" if d.get("IPAPI_ORG") and d["IPAPI_ORG"] != d["IPAPI_ISP"] else "")
        lines.append(f"🏠 Провайдер (как на 2ip): {esc(isp)}")
    if d.get("HOST"):
        lines.append(f"🏷 Имя адреса: {esc(d['HOST'])}")
    lines += [f"🖥 {esc(d.get('OS', '?'))} · память {ram} · диск {esc(d.get('DISK', '?'))}", "",
              "🗺 <b>Как видят страну:</b>",
              f"   ipinfo: {esc(country)}{' (' + esc(d['CITY']) + ')' if d.get('CITY') else ''} · "
              f"ip-api: {esc(d.get('IPAPI_COUNTRY', '?'))} · реестр: {esc(d.get('REG_COUNTRY', '?'))}",
              f"   Google: <b>{esc(gl)}</b> {'❌' if gl == 'RU' else ('✅' if gl not in ('?', '') else '❔')}"]
    marks = [m for k, m in (("IPAPI_HOSTING", "хостинг"), ("IPAPI_PROXY", "прокси/VPN")) if d.get(k) == "yes"]
    if marks:
        lines.append(f"🚩 Метки в базах: {', '.join(marks)}" + (" — плохо для нейронок" if "прокси/VPN" in marks else " — это норма для VPS"))
    lines += ["",
              "🤖 Нейронки (по признакам с сервера):",
              "   " + "  ".join(f"{k} {YES_NO.get(v, '❔')}" for k, v in ai.items()), ""]
    if asn in PROBE_BAD:
        lines.append(f"🗑 <b>Удаляй, пока не списали деньги.</b>\n{asn}: {PROBE_BAD[asn]}.")
    else:
        if asn in PROBE_WARN:
            lines.append(f"⚠️ {PROBE_WARN[asn]}")
        if gl == "RU" or ai["Gemini"] == "no":
            lines.append("⚠️ <b>Gemini тут не пойдёт.</b> Под VPN, Telegram и ChatGPT/Claude — годится.")
        elif "?" in (gl, ai["Gemini"]):
            lines.append("❔ Часть проверок не ответила. Повтори через минуту.")
        else:
            lines.append("✅ <b>Похоже, годен.</b> Последнее слово — Gemini вживую с телефона без VPN, "
                         "после установки нейронок.")
        if gl not in ("?", "", country) and country not in ("?", ""):
            lines.append(f"ℹ️ Базы говорят {esc(country)}, а Google считает {esc(gl)} — Google тут главнее.")
    return "\n".join(lines)


# ───────────────────────── WARP ─────────────────────────
WARP_ABOUT = ("🌐 <b>WARP</b> — выход в интернет через Cloudflare, а не с адреса сервера.\n\n"
              "Зачем: сайты видят адрес Cloudflare. Помогает, когда сайт не пускает адрес сервера, "
              "и прячет сервер от лишних глаз.\n"
              "Включается по устройствам: кому-то через WARP, кому-то напрямую. Для VLESS и AmneziaWG.")
PROTO = {"vless": "VLESS", "awg": "AmneziaWG"}


def warp_screen(chat):
    info = kb_json("warp", "info")
    if not info.get("installed"):
        send(chat, WARP_ABOUT, inline([btn("🚀 Установить", "warp:install")]))
        return
    devs = info.get("devices") or []
    head = (f"🌐 <b>WARP</b> — {'работает ✅' if info.get('up') else 'не поднят ❌'}"
            f"{', выход ' + esc(info['ip']) if info.get('ip') else ''}\n\n")
    if not devs:
        send(chat, head + "Устройств пока нет — добавь их в 🔑 VLESS или 🛡 AmneziaWG.", warp_tail())
        return
    rows = [[btn(f"{'✅' if d['on'] else '⬜'} {d['name']} · {PROTO.get(d['proto'], d['proto'])}",
                 f"warp:t:{d['proto']}:{d['name']}:{'off' if d['on'] else 'on'}")] for d in devs[:40]]
    send(chat, head + "Нажми на устройство, чтобы переключить.\n✅ — через WARP, ⬜ — напрямую.",
         {"inline_keyboard": rows + warp_tail()["inline_keyboard"]})


def warp_tail():
    return inline([btn("✅ Всех через WARP", "warp:all:on"), btn("⬜ Всех напрямую", "warp:all:off")],
                  [btn("📊 Состояние", "warp:status"), btn("🔁 Новый ключ WARP", "warp:reissue")],
                  [btn("🗑 Удалить WARP", "warp:rm")])


def warp_callback(chat, data):
    if data == "warp:install":
        def job():
            code, out = kb("warp", "install", timeout=600)
            if code != 0:
                send_pre(chat, "\n".join(out.splitlines()[-20:]), "❌ Не встало. Последние строки:",
                         inline([btn("🚀 Попробовать снова", "warp:install")]))
                return
            send_pre(chat, "\n".join(out.splitlines()[-4:]), "✅ WARP готов")
            warp_screen(chat)
        run_long(chat, "Ставлю WARP. Это минута.", job)
    elif data.startswith("warp:t:"):
        _, _, proto, name, want = data.split(":", 4)
        code, out = kb("warp", want, proto, name, timeout=60)
        if code != 0:
            send_pre(chat, out, "❌ Не переключилось")
        warp_screen(chat)
    elif data.startswith("warp:all:"):
        kb("warp", "all-" + data.split(":")[2], timeout=90)
        warp_screen(chat)
    elif data == "warp:status":
        send_pre(chat, kb("warp", "status", timeout=60)[1], "📊 WARP", inline([btn("◀️ Назад в WARP", "warp:menu")]))
    elif data == "warp:reissue":
        run_long(chat, "Перевыпускаю ключ WARP…",
                 lambda: (send_pre(chat, kb("warp", "reissue", timeout=180)[1], "🔁 Готово"), warp_screen(chat)))
    elif data == "warp:rm":
        send(chat, "🗑 Удалить WARP? Все устройства пойдут напрямую, ключи VPN останутся.",
             inline([btn("Да, удалить", "warp:rmok")], CANCEL))
    elif data == "warp:rmok":
        send_pre(chat, kb("warp", "remove", timeout=120)[1], "🗑 Готово")
        warp_screen(chat)
    elif data == "warp:menu":
        warp_screen(chat)


# ───────────────────────── Telegram-прокси ─────────────────────────
TGP_ABOUT = ("✈️ <b>Telegram-прокси</b> — Telegram без VPN, когда он не грузится.\n\n"
             "Одна ссылка: нажал — Telegram спросит «Подключить прокси?» → «Подключить». Всё.\n"
             "Работает: сообщения, фото, видео, кружки, голосовые.\n"
             "Не работает: звонки — они идут мимо прокси. Для звонков нужен VPN.")


def tgp_screen(chat):
    """Три вида прокси рядом: общая ссылка (mtg), личные ссылки (telemt), WEB-ссылка (tproxy-server)."""
    old, new, web = kb_json("tgproxy", "info"), kb_json("tgusers", "info"), kb_json("tgweb", "info")
    st = lambda i: ("работает ✅" if i.get("running") else "не запущен ❌") if i.get("installed") else "не стоит"
    text = ("✈️ <b>Telegram-прокси</b> — Telegram без VPN.\n"
            "Работают сообщения, фото, видео, голосовые. Звонки — нет, для них нужен VPN.\n\n"
            f"🔗 <b>Общая ссылка</b> — {st(old)}\n"
            "Одна ссылка на всех. Проще всего, но отключить одного человека нельзя.\n\n"
            f"👤 <b>Личные ссылки</b> — {st(new)}\n"
            "У каждого своя ссылка: видно трафик, можно выключить одного, остальные работают.\n\n"
            f"🌐 <b>WEB-ссылка</b> — {st(web)}\n"
            "Новый вид прокси Telegram: снаружи это обычный сайт. Нужен свой домен.")
    rows = []
    if old.get("installed"):
        rows.append([btn("🔗 Общая: ссылка и QR", "tgp:link"), btn("🗑 Убрать общую", "tgp:rm")])
    else:
        rows.append([btn("🔗 Поставить общую ссылку", "tgp:install")])
    if new.get("installed"):
        rows.append([btn("👤 Личные: список людей", "tgu:menu")])
    else:
        rows.append([btn("👤 Поставить личные ссылки", "tgu:install")])
    rows.append([btn("🌐 WEB-ссылка", "tgw:menu")])
    send(chat, text, {"inline_keyboard": rows})


# ── WEB-прокси (tproxy-server + официальный MTProxy) ──
TGW_ABOUT = ("🌐 <b>WEB-ссылка</b> — новый вид прокси Telegram (WEB Proxy).\n\n"
             "Telegram ходит по HTTPS на твой сайт <code>{host}</code> — для провайдера это обычный сайт. "
             "Может пригодиться, если обычные прокси начнут резать.\n"
             "Нужно новое приложение Telegram: старое скажет «прокси не поддерживается».\n\n"
             "Ставится долго: сборка из исходников, 5–10 минут и ~1,5 ГБ на диске.\n"
             "Звонков нет, как у любого прокси.")


def tgw_screen(chat):
    info = kb_json("tgweb", "info")
    if info.get("installed"):
        st = "работает ✅" if info.get("running") else "не запущен ❌"
        send(chat, f"🌐 <b>WEB-ссылка</b> — {st}\nСайт: <code>{esc(info.get('host', ''))}</code>",
             inline([btn("🔗 Ссылка и QR", "tgw:link"), btn("📊 Состояние", "tgw:status")],
                    [btn("🗑 Убрать WEB-ссылку", "tgw:rm"), btn("◀️ Назад", "tgp:menu")]))
        return
    if not info.get("safe"):
        send(chat, TGW_ABOUT.format(host="tg.твой-домен") + "\n\n⚠️ Сначала положи <b>домен</b> и <b>ключ Cloudflare</b> в 🔐 Сейф.",
             inline([btn("🔐 Открыть сейф", "safe:open")], [btn("◀️ Назад", "tgp:menu")]))
        return
    text = TGW_ABOUT.format(host=esc(info.get("want_host", "")))
    if info.get("vless") and not info.get("vless_domain"):
        text += ("\n\n⚠️ Вход на сайт держит 🔑 VLESS, а он сейчас на чужой маске "
                 f"({esc(info.get('vless_mask', ''))}). Переведу его на твой домен — "
                 "<b>ключи у всех VLESS-устройств сменятся</b>, QR придётся отсканировать заново.")
        rows = [[btn("🚀 Ставить (ключи VLESS сменятся)", "tgw:go1")]]
    else:
        if not info.get("vless"):
            text += "\n\nЗаодно поставлю 🔑 VLESS на твоём домене — через него идёт вход на сайт."
        rows = [[btn("🚀 Поставить", "tgw:go")]]
    rows.append([btn("◀️ Назад", "tgp:menu")])
    send(chat, text, {"inline_keyboard": rows})


def tgw_send_link(chat):
    code, link = kb("tgweb", "link", timeout=30)
    if code != 0:
        send(chat, "❌ " + esc(last_line(link)), inline([btn("◀️ Назад", "tgw:menu")]))
        return
    qcode, png = kb_raw("tgweb", "qr-png")
    if qcode == 0 and png:
        send_file(chat, "sendPhoto", "photo", "telegram-web-proxy.png", png,
                  "QR: открой камерой телефона, где стоит Telegram", "image/png")
    send(chat, f"WEB-ссылка — нажми её на устройстве с Telegram:\n{esc(last_line(link))}\n\n"
               "Telegram старой версии её не поймёт — обнови приложение.",
         inline([btn("🔁 Прислать ещё раз", "tgw:link"), btn("◀️ Назад", "tgw:menu")]))


def tgw_callback(chat, data):
    if data in ("tgw:go", "tgw:go1"):
        def job():
            env = {"KB_SERVER_IP": aip_info().get("server_ip", "")}
            if data == "tgw:go1":
                env["KB_TGW_SWITCH"] = "1"
            code, out = kb("tgweb", "install", env=env, timeout=2400)
            os.makedirs(LOG_DIR, exist_ok=True)
            with open(os.path.join(LOG_DIR, "tgweb-install.log"), "w") as f:
                f.write(out)
            if code != 0:
                send_pre(chat, "\n".join(out.splitlines()[-20:]), "❌ Не встало. Последние строки:",
                         inline([btn("🔁 Попробовать снова", data)], [btn("◀️ Назад", "tgw:menu")]))
                return
            send_pre(chat, "\n".join(out.splitlines()[-10:]), "✅ WEB-ссылка готова.")
            if data == "tgw:go1":
                vls_after_switch(chat, "VLESS теперь на своём домене", "🔑 VLESS переехал на твой домен.")
            tgw_send_link(chat)
        run_long(chat, "Ставлю WEB-ссылку: собираю из исходников, 5–10 минут. Напишу, как закончу.", job)
    elif data == "tgw:link":
        tgw_send_link(chat)
    elif data == "tgw:status":
        send_pre(chat, kb("tgweb", "status", timeout=60)[1], "📊 WEB-ссылка", inline([btn("◀️ Назад", "tgw:menu")]))
    elif data == "tgw:rm":
        send(chat, "🗑 Убрать WEB-ссылку? Она перестанет работать у всех, кому ты её давал.",
             inline([btn("Да, убрать", "tgw:rmok")], [btn("◀️ Назад", "tgw:menu")]))
    elif data == "tgw:rmok":
        send_pre(chat, kb("tgweb", "remove", timeout=180)[1], "🗑 Готово")
        tgp_screen(chat)
    elif data == "tgw:menu":
        tgw_screen(chat)


# ── прокси по именам (telemt) ──
def fmt_mb(b):
    return f"{(b or 0) / 1048576:.1f} МБ"


def tgu_screen(chat, info=None):
    info = info or kb_json("tgusers", "info")
    users = info.get("users") or []
    head = (f"👤 <b>Личные ссылки</b> — {'работает ✅' if info.get('running') else 'не запущен ❌'}, "
            f"порт {info.get('port', '')}\n\n"
            "Нажми на человека — ссылка, выключить, удалить.\n✅ — пускает, ⛔ — выключен.")
    rows = [[btn(f"{'✅' if u['on'] else '⛔'} {u['name']} · {fmt_mb(u.get('bytes'))}"
                 f"{' · онлайн' if u.get('conns') else ''}", f"tgu:u:{u['name']}")] for u in users[:40]]
    if not info.get("running"):
        rows.insert(0, [btn("🔧 Не запущен — переставить начисто", "tgu:install")])
    rows += [[btn("➕ Добавить человека", "tgu:add")],
             [btn("🗑 Убрать личные ссылки целиком", "tgu:rm"), btn("◀️ Назад", "tgp:menu")]]
    send(chat, head, {"inline_keyboard": rows})


def tgu_user(chat, name):
    users = {u["name"]: u for u in (kb_json("tgusers", "info").get("users") or [])}
    u = users.get(name)
    if not u:
        send(chat, "Такого уже нет.", inline([btn("◀️ Назад", "tgu:menu")]))
        return
    send(chat, f"👤 <b>{esc(name)}</b> — {'пускает ✅' if u['on'] else 'выключен ⛔'}\n"
               f"Трафик: {fmt_mb(u.get('bytes'))}, сейчас подключений: {u.get('conns', 0)}, адресов: {u.get('ips', 0)}",
         inline([btn("🔗 Ссылка и QR", f"tgu:link:{name}")],
                [btn("⛔ Выключить", f"tgu:off:{name}") if u["on"] else btn("✅ Включить", f"tgu:on:{name}"),
                 btn("🔁 Новый ключ", f"tgu:rot:{name}")],
                [btn("🗑 Удалить", f"tgu:del:{name}"), btn("◀️ Назад", "tgu:menu")]))


def tgu_send_link(chat, name):
    code, link = kb("tgusers", "link", name, timeout=20)
    link = link.strip()
    if code != 0 or not link.startswith("tg://"):
        send(chat, "❌ Не получилось взять ссылку.", inline([btn("◀️ Назад", "tgu:menu")]))
        return
    qcode, png = kb_raw("tgusers", "qr-png", name)
    if qcode == 0 and png:
        send_file(chat, "sendPhoto", "photo", f"{name}.png", png,
                  f"QR для «{name}»: открыть камерой телефона, где стоит Telegram", "image/png")
    web = "https://t.me/proxy?" + link.split("?", 1)[1]
    send(chat, f"Ссылка для «{esc(name)}» — у него своя, другим не подойдёт:\n{esc(web)}",
         inline([btn("🔁 Прислать ещё раз", f"tgu:link:{name}"), btn("◀️ Назад", "tgu:menu")]))


def tgu_add_name(chat, text):
    state.pop(chat, None)
    name = text.strip().lower()
    if not CLIENT_RE.match(name):
        send(chat, "Только маленькие латинские буквы, цифры и дефис.", inline([btn("Ещё раз", "tgu:add")]))
        return
    code, out = kb("tgusers", "add", name, timeout=30)
    if code != 0:
        send_pre(chat, out, "❌ Не добавился", inline([btn("🔁 Ещё раз", "tgu:add"), btn("◀️ Назад", "tgu:menu")]))
        return
    tgu_send_link(chat, name)


def tgu_callback(chat, data):
    if data == "tgu:install":
        def job():
            code, out = kb("tgusers", "install", timeout=300)
            if code != 0:
                send_pre(chat, "\n".join(out.splitlines()[-15:]), "❌ Не встало. Последние строки:",
                         inline([btn("🚀 Попробовать снова", "tgu:install")]))
                return
            send_pre(chat, "\n".join(out.splitlines()[-3:]), "✅ Готово")
            tgu_screen(chat)
        run_long(chat, "Ставлю личные ссылки. Это минута.", job)
    elif data == "tgu:menu":
        tgu_screen(chat)
    elif data == "tgu:add":
        state[chat] = {"step": "tgu_add"}
        send(chat, "👤 Как назвать человека? Латиницей, например <code>petya</code>.\n"
                   "Это подпись в списке — чтобы потом знать, чья ссылка.", inline(CANCEL))
    elif data.startswith("tgu:u:"):
        tgu_user(chat, data.split(":", 2)[2])
    elif data.startswith("tgu:link:"):
        tgu_send_link(chat, data.split(":", 2)[2])
    elif data.startswith(("tgu:on:", "tgu:off:", "tgu:rot:")):
        act, name = data.split(":")[1], data.split(":", 2)[2]
        cmd = {"on": "enable", "off": "disable", "rot": "rotate"}[act]
        code, out = kb("tgusers", cmd, name, timeout=30)
        if code != 0:
            send_pre(chat, out, "❌ Не получилось")
        if act == "rot" and code == 0:
            tgu_send_link(chat, name)
        else:
            tgu_user(chat, name)
    elif data.startswith("tgu:del:"):
        name = data.split(":", 2)[2]
        send(chat, f"🗑 Удалить «{esc(name)}»? Его ссылка сразу перестанет работать.",
             inline([btn("Да, удалить", f"tgu:delok:{name}")], [btn("◀️ Назад", "tgu:menu")]))
    elif data.startswith("tgu:delok:"):
        kb("tgusers", "del", data.split(":", 2)[2], timeout=30)
        tgu_screen(chat)
    elif data == "tgu:rm":
        send(chat, "🗑 Убрать личные ссылки целиком? Перестанут работать ссылки у всех людей из списка.",
             inline([btn("Да, удалить", "tgu:rmok")], [btn("◀️ Назад", "tgu:menu")]))
    elif data == "tgu:rmok":
        send_pre(chat, kb("tgusers", "remove", timeout=60)[1], "🗑 Готово")
        tgp_screen(chat)


def tgp_send_link(chat):
    info = kb_json("tgproxy", "info")
    if not info.get("installed"):
        tgp_screen(chat)
        return
    code, png = kb_raw("tgproxy", "qr-png")
    if code == 0 and png:
        send_file(chat, "sendPhoto", "photo", "telegram-proxy.png", png,
                  "QR: открой камерой телефона, где стоит Telegram", "image/png")
    send(chat, f"Ссылка — нажми её на устройстве с Telegram или перешли тому, кому нужно:\n{esc(info['web'])}\n\n"
               "Звонки через прокси не работают — для них нужен VPN.",
         inline([btn("🔁 Прислать ещё раз", "tgp:link"), btn("◀️ Назад", "tgp:menu")]))


def tgp_callback(chat, data):
    if data == "tgp:install":
        def job():
            code, out = kb("tgproxy", "install", timeout=300)
            if code != 0:
                send_pre(chat, "\n".join(out.splitlines()[-15:]), "❌ Не встало. Последние строки:",
                         inline([btn("🚀 Попробовать снова", "tgp:install")]))
                return
            send(chat, "✅ Telegram-прокси работает.")
            tgp_send_link(chat)
        run_long(chat, "Ставлю Telegram-прокси. Это минута.", job)
    elif data == "tgp:link":
        tgp_send_link(chat)
    elif data == "tgp:rm":
        send(chat, "🗑 Убрать общую ссылку? Она перестанет работать у всех, кому ты её давал.",
             inline([btn("Да, удалить", "tgp:rmok")], CANCEL))
    elif data == "tgp:rmok":
        send_pre(chat, kb("tgproxy", "remove", timeout=60)[1], "🗑 Готово")
        tgp_screen(chat)
    elif data == "tgp:menu":
        tgp_screen(chat)


# ───────────────────────── обновление Комбайна ─────────────────────────
UPD_FLAG = "/opt/kombain/bot/updated"   # кому сказать «готово» после перезапуска


def upd_callback(chat, data):
    if data == "upd:ask":
        send(chat, f"🔄 Сейчас стоит Комбайн <b>{VERSION}</b>.\n\n"
                   "Скачаю свежую версию с GitHub и перезапущу бота — это секунд 20. "
                   "VPN, нейронки и ключи не тронет: они работают сами по себе.",
             inline([btn("✅ Обновить", "upd:go")], CANCEL))
    elif data == "upd:go":
        def job():
            r = subprocess.run([KB, "--update", "cli", "secrets", "info"], capture_output=True, text=True,
                               timeout=300, stdin=subprocess.DEVNULL,
                               env={k: v for k, v in os.environ.items() if k != "BOT_TOKEN"})
            if r.returncode != 0:
                send_pre(chat, (r.stdout + r.stderr)[-1500:], "❌ Не обновилось. Последние строки:",
                         inline([btn("🔁 Попробовать ещё раз", "upd:go")]))
                return
            with open(UPD_FLAG, "w") as f:
                f.write(f"{chat} {VERSION}\n")
            send(chat, "📦 Скачала. Перезапускаю бота…")
            subprocess.run(["systemd-run", "--on-active=2", "--unit=kombain-bot-update", "--collect",
                            "systemctl", "restart", "kombain-bot"], capture_output=True)
        run_long(chat, "Обновляю Комбайн…", job)


def upd_report():
    """После перезапуска: сказать, что обновились, и с какой версии на какую."""
    try:
        with open(UPD_FLAG) as f:
            chat, old = f.read().split()
        os.remove(UPD_FLAG)
    except (OSError, ValueError):
        return
    if old == VERSION:
        send(int(chat), f"✅ Готово. Версия та же — <b>{VERSION}</b>, обновлять было нечего.", MAIN_KB)
    else:
        send(int(chat), f"✅ Обновилась: <b>{old} → {VERSION}</b>.", MAIN_KB)


HELP = (f"🤖 <b>Пульт Комбайна</b> · {VERSION}\n\n"
        "🧠 <b>Нейронки</b> — ChatGPT, Gemini, Claude без VPN, через DNS.\n"
        "🔐 <b>Сейф</b> — место сбора: сюда складываешь всё для установки, потом одна кнопка.\n"
        "🔑 <b>VLESS</b> — VPN под видом обычного сайта, режут реже всего.\n"
        "🛡 <b>AmneziaWG</b> — VPN 3.1: установка, ключи и QR для устройств.\n"
        "🌐 <b>WARP</b> — выход через Cloudflare: включаешь по устройствам.\n"
        "✈️ <b>Telegram</b> — прокси, чтобы Telegram работал без VPN.\n"
        "📊 <b>Сервер</b> — IP, память, диск, что запущено.\n"
        "➕ <b>Новый сервер</b> — купил сервер? Проверю его до установки: /new\n"
        "🗂 <b>Мои серверы</b> — оставленные серверы, управлять ими отсюда: /servers, назад к своему — /local\n\n"
        "\n"
        "Обновить Комбайн — /update или «📊 Сервер» → «🔄 Обновить».\n"
        "Отменить любой шаг — /cancel.")


def on_message(m):
    chat = m["chat"]["id"]
    text = m.get("text") or ""
    if text == "/update":
        upd_callback(chat, "upd:ask")
        return
    if text in ("/start", "/menu"):
        state.pop(chat, None)
        send(chat, f"Привет! Я пульт твоего сервера. Комбайн {VERSION}.\nВыбирай внизу 👇", MAIN_KB)
        return
    if text == "/new":
        probe_ask(chat)
        return
    if text == "/servers":
        srv_list(chat)
        return
    if text == "/local":
        srv_local(chat)
        return
    if text == "/cancel":
        state.pop(chat, None)
        send(chat, "Отменено.", MAIN_KB)
        return
    screens = {B_AI: ai_screen, B_AWG: awg_screen, B_VLS: vls_screen, B_WARP: warp_screen, B_TGP: tgp_screen, B_SAFE: safe_screen, B_SERVER: server_screen,
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
    elif step == "awg_add":
        awg_add(chat, text)
    elif step == "vls_add":
        vls_add(chat, text)
    elif step == "tgu_add":
        tgu_add_name(chat, text)
    elif step == "probe_host":
        probe_host(chat, text)
    elif step == "probe_pass":
        probe_pass(chat, text, m["message_id"])
    elif step == "srv_pass":
        srv_pass(chat, text, m["message_id"])
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
        send(chat, "Отменено.", MAIN_KB)
    elif data == "home":
        state.pop(chat, None)
        send(chat, f"🏠 Главное меню · Комбайн {VERSION}\nВыбирай кнопкой внизу 👇", MAIN_KB)
    elif data.startswith("safe:"):
        safe_callback(chat, data)
    elif data.startswith("aip:"):
        ai_callback(chat, data)
    elif data.startswith("awg:"):
        awg_callback(chat, data)
    elif data.startswith("vls:"):
        vls_callback(chat, data)
    elif data == "probe:ask":
        probe_ask(chat)
    elif data.startswith("srv:"):
        srv_callback(chat, data)
    elif data.startswith("upd:"):
        upd_callback(chat, data)
    elif data.startswith("warp:"):
        warp_callback(chat, data)
    elif data.startswith("tgp:"):
        tgp_callback(chat, data)
    elif data.startswith("tgw:"):
        tgw_callback(chat, data)
    elif data.startswith("tgu:"):
        tgu_callback(chat, data)


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
    try:
        upd_report()
    except Exception:
        traceback.print_exc()
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
