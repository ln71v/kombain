package io.github.ln71v.kombain;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.view.View;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.regex.Pattern;

import kbcore.Kbcore;

/**
 * Комбайн для телефона. Окно — тот же интерфейс, что у kombain-start.exe (starter/ui/index.html),
 * логика — то же Go-ядро (starter/backend.go). Здесь только окно и кнопки «открыть Telegram».
 */
public class MainActivity extends Activity {

    private static final Pattern PROXY_TG = Pattern.compile(
            "^tg://proxy\\?server=[0-9.]{7,15}&port=[0-9]{2,5}&secret=ee[0-9a-f]{20,200}$");
    private static final Pattern BOT_NAME = Pattern.compile("^[A-Za-z0-9_]{5,32}$");
    // Внешние ссылки из окна — только эти: Telegram-чат по имени и страница Комбайна на GitHub.
    private static final Pattern LINK_OK = Pattern.compile(
            "^https://t\\.me/[A-Za-z0-9_]{5,32}$|^https://github\\.com/ln71v/kombain(/releases)?$");
    static final String ACTION_INSTALLED = "io.github.ln71v.kombain.INSTALLED";

    private WebView web;
    private Updater updater;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        // Пока идёт установка, экран не гаснет: иначе телефон может усыпить программу.
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        // Отпечатки серверов — в личной папке приложения: при следующем входе сверим ключ сервера.
        Kbcore.setDataDir(getFilesDir().getAbsolutePath());
        updater = new Updater(this, getString(R.string.kb_channel));
        // Пароль root не предлагать «сохранить» — автозаполнение Samsung/Google в окне выключено.
        getWindow().getDecorView().setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);

        web = new WebView(this);
        web.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
        web.setBackgroundColor(0xFFFBFAF7);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(false);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setGeolocationEnabled(false);
        s.setSupportZoom(false);
        s.setMediaPlaybackRequiresUserGesture(true);
        //noinspection deprecation
        s.setSaveFormData(false);
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                // Внутри окна никуда не уходим. Ссылки (GitHub и т.п.) — в браузер телефона.
                Uri u = req.getUrl();
                if ("https".equals(u.getScheme())) open(u);
                return true;
            }
        });
        web.addJavascriptInterface(new Bridge(), "KombainNative");
        web.loadDataWithBaseURL("https://kombain.invalid/", page(), "text/html", "utf-8", null);
        setContentView(web);
        if (ACTION_INSTALLED.equals(getIntent().getAction())) updater.onInstallResult(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (ACTION_INSTALLED.equals(intent.getAction())) updater.onInstallResult(intent);
    }

    /** Текст из буфера обмена — по кнопке «Вставить». Читаем только по нажатию. */
    private String clipboard() {
        AtomicReference<String> res = new AtomicReference<>("");
        CountDownLatch done = new CountDownLatch(1);
        runOnUiThread(() -> {
            try {
                ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                ClipData c = cm == null ? null : cm.getPrimaryClip();
                if (c != null && c.getItemCount() > 0) {
                    CharSequence t = c.getItemAt(0).coerceToText(MainActivity.this);
                    if (t != null) res.set(t.toString());
                }
            } catch (Exception ignored) {
            }
            done.countDown();
        });
        try {
            done.await(3, TimeUnit.SECONDS);
        } catch (InterruptedException ignored) {
        }
        String t = res.get();
        return t.length() > 4096 ? "" : t;
    }

    /** index.html от exe + мост и подгонка под телефон. */
    private String page() {
        String html = asset("index.html");
        String css = asset("mobile.css");
        String js = asset("mobile.js");
        html = html.replaceFirst("<head>", "<head><script>" + quote(js) + "</script>");
        html = html.replaceFirst("</head>", "<style>" + quote(css) + "</style></head>");
        return html;
    }

    private static String quote(String s) {
        return s.replace("\\", "\\\\").replace("$", "\\$");
    }

    private String asset(String name) {
        try (InputStream in = getAssets().open(name)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toString(StandardCharsets.UTF_8.name());
        } catch (IOException e) {
            return "";
        }
    }

    private boolean open(Uri uri) {
        try {
            Intent i = new Intent(Intent.ACTION_VIEW, uri);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
            return true;
        } catch (ActivityNotFoundException e) {
            return false;
        }
    }

    private static String reply(Object result, String error) {
        try {
            JSONObject o = new JSONObject();
            o.put("result", result == null ? JSONObject.NULL : result);
            if (error != null) o.put("error", error);
            return o.toString();
        } catch (Exception e) {
            return "{\"error\":\"Не получилось выполнить шаг. Попробуй ещё раз.\"}";
        }
    }

    private String version() {
        try {
            return "v" + getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "";
        }
    }

    /** То, что окно может попросить. Всё остальное уходит в Go-ядро. */
    private final class Bridge {
        @JavascriptInterface
        public String call(String name, String args) {
            switch (name) {
                case "appVersion":
                    return reply(version(), null);
                case "closeWindow":
                    runOnUiThread(MainActivity.this::finishAndRemoveTask);
                    return reply(null, null);
                case "openProxy":
                    return openProxy();
                case "openBot":
                    return openBot(args);
                case "openLink":
                    return openLink(args);
                case "readClipboard":
                    return reply(clipboard(), null);
                case "updateCheck":
                    updater.check();
                    return reply(null, null);
                case "updateState":
                    try {
                        return reply(new JSONObject(updater.stateJson()), null);
                    } catch (Exception e) {
                        return reply(null, null);
                    }
                case "updateInstall":
                    updater.install();
                    return reply(null, null);
                default:
                    return Kbcore.call(name, args);
            }
        }

        private String openProxy() {
            try {
                JSONObject r = new JSONObject(Kbcore.call("proxyLink", "[]"));
                String err = r.optString("error", "");
                if (!err.isEmpty()) return reply(null, err);
                String link = r.optString("result", "");
                if (!PROXY_TG.matcher(link).matches()) return reply(null, "Сначала поставь прокси.");
                if (open(Uri.parse(link))) return reply(null, null);
                return reply(null, "Telegram на телефоне не найден. Поставь Telegram или скопируй ссылку и открой её в нём.");
            } catch (Exception e) {
                return reply(null, "Не открылось. Скопируй ссылку и открой её в Telegram.");
            }
        }

        private String openLink(String args) {
            try {
                String url = new org.json.JSONArray(args).optString(0, "");
                if (!LINK_OK.matcher(url).matches()) return reply(null, "Такую ссылку не открываю.");
                if (url.startsWith("https://t.me/")) {
                    String name = url.substring("https://t.me/".length());
                    if (open(Uri.parse("tg://resolve?domain=" + name))) return reply(null, null);
                }
                if (open(Uri.parse(url))) return reply(null, null);
                return reply(null, "Не открылось. Telegram на телефоне стоит?");
            } catch (Exception e) {
                return reply(null, "Не открылось.");
            }
        }

        private String openBot(String args) {
            try {
                String name = new org.json.JSONArray(args).optString(0, "");
                if (!BOT_NAME.matcher(name).matches()) return reply(null, "Нет имени бота.");
                if (open(Uri.parse("tg://resolve?domain=" + name))) return reply(null, null);
                if (open(Uri.parse("https://t.me/" + name))) return reply(null, null);
                return reply(null, "Telegram на телефоне не найден.");
            } catch (Exception e) {
                return reply(null, "Не открылось.");
            }
        }
    }

    @Override
    public void onBackPressed() {
        new AlertDialog.Builder(this)
                .setMessage("Закрыть Комбайн? Если сейчас идёт установка — она прервётся.")
                .setPositiveButton("Закрыть", (d, w) -> finishAndRemoveTask())
                .setNegativeButton("Остаться", null)
                .show();
    }

    @Override
    protected void onDestroy() {
        if (isFinishing()) Kbcore.close(); // рвём связь с сервером, пароль и токен уходят из памяти
        if (web != null) {
            web.removeJavascriptInterface("KombainNative");
            web.destroy();
        }
        super.onDestroy();
    }
}
