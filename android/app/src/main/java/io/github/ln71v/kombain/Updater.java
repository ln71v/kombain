package io.github.ln71v.kombain;

import android.app.Activity;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.net.Uri;
import android.provider.Settings;

import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Locale;

/**
 * Обновление Комбайна прямо из приложения.
 * Сверяет контрольную сумму своего APK с файлом *.sha256 на GitHub. Не совпала — есть новая сборка.
 * Качает APK, сверяет сумму и отдаёт Android на установку (тот сам спросит «Обновить?»).
 * Встанет поверх, только если новая сборка подписана тем же ключом.
 */
final class Updater {
    private static final String REPO = "https://github.com/ln71v/kombain/releases/";
    private static final long MAX_APK = 80L * 1024 * 1024;

    private final Activity act;
    private final String base;
    private volatile String state = "none";   // none | checking | available | downloading | installing | permission | error
    private volatile String message = "";
    private volatile String remoteSum = "";

    Updater(Activity act, String channel) {
        this.act = act;
        // Тестовая сборка обновляется из android-test, обычная — из последнего релиза.
        this.base = "test".equals(channel) ? REPO + "download/android-test/" : REPO + "latest/download/";
    }

    String stateJson() {
        try {
            JSONObject o = new JSONObject();
            o.put("state", state);
            o.put("message", message);
            return o.toString();
        } catch (Exception e) {
            return "{}";
        }
    }

    void check() {
        if (!"none".equals(state) && !"error".equals(state)) return;
        state = "checking";
        new Thread(() -> {
            try {
                String line = new String(get(base + "kombain-android.apk.sha256", 4096), StandardCharsets.UTF_8).trim();
                String sum = line.split("\\s+")[0].toLowerCase(Locale.ROOT);
                if (!sum.matches("[0-9a-f]{64}")) { state = "none"; return; }
                String mine = sha256(new File(act.getPackageCodePath()));
                remoteSum = sum;
                state = sum.equals(mine) ? "none" : "available";
            } catch (Exception e) {
                state = "none"; // нет связи с GitHub — просто молчим
            }
        }).start();
    }

    void install() {
        if ("downloading".equals(state)) return;
        if (!act.getPackageManager().canRequestPackageInstalls()) {
            state = "permission";
            act.runOnUiThread(() -> {
                try {
                    act.startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:" + act.getPackageName())));
                } catch (Exception ignored) {
                }
            });
            return;
        }
        state = "downloading";
        message = "";
        new Thread(() -> {
            File apk = new File(act.getCacheDir(), "update.apk");
            try {
                download(base + "kombain-android.apk", apk);
                if (remoteSum.isEmpty() || !remoteSum.equals(sha256(apk))) {
                    fail("Файл скачался битым. Попробуй ещё раз.");
                    return;
                }
                PackageInstaller pi = act.getPackageManager().getPackageInstaller();
                PackageInstaller.SessionParams p = new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
                p.setAppPackageName(act.getPackageName());
                int id = pi.createSession(p);
                try (PackageInstaller.Session s = pi.openSession(id)) {
                    try (InputStream in = new FileInputStream(apk); OutputStream out = s.openWrite("kombain.apk", 0, apk.length())) {
                        byte[] buf = new byte[65536];
                        int n;
                        while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                        s.fsync(out);
                    }
                    Intent back = new Intent(act, MainActivity.class).setAction(MainActivity.ACTION_INSTALLED)
                            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
                    PendingIntent pend = PendingIntent.getActivity(act, 7, back,
                            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
                    s.commit(pend.getIntentSender());
                }
                state = "installing";
            } catch (Exception e) {
                fail("Не получилось скачать обновление. Проверь интернет и попробуй ещё раз.");
            } finally {
                //noinspection ResultOfMethodCallIgnored
                apk.delete();
            }
        }).start();
    }

    /** Ответ Android на установку: попросить человека подтвердить или показать ошибку. */
    void onInstallResult(Intent i) {
        int status = i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            Intent confirm = i.getParcelableExtra(Intent.EXTRA_INTENT);
            if (confirm != null) {
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                act.startActivity(confirm);
            }
            return;
        }
        if (status == PackageInstaller.STATUS_SUCCESS) {
            state = "none";
            return;
        }
        if (status == PackageInstaller.STATUS_FAILURE_CONFLICT || status == PackageInstaller.STATUS_FAILURE_INCOMPATIBLE) {
            fail("Новая версия подписана другим ключом — поверх не встанет. Удали Комбайн и поставь заново с GitHub.");
        } else if (status == PackageInstaller.STATUS_FAILURE_ABORTED) {
            state = "available"; // человек нажал «Отмена»
        } else {
            fail("Android не стал ставить обновление. Попробуй ещё раз.");
        }
    }

    private void fail(String m) {
        message = m;
        state = "error";
    }

    private static byte[] get(String url, int limit) throws Exception {
        HttpURLConnection c = open(url);
        try (InputStream in = c.getInputStream()) {
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
                if (out.size() > limit) throw new Exception("too big");
            }
            return out.toByteArray();
        } finally {
            c.disconnect();
        }
    }

    private static void download(String url, File to) throws Exception {
        HttpURLConnection c = open(url);
        long total = 0;
        try (InputStream in = c.getInputStream(); OutputStream out = new FileOutputStream(to)) {
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) > 0) {
                total += n;
                if (total > MAX_APK) throw new Exception("too big");
                out.write(buf, 0, n);
            }
        } finally {
            c.disconnect();
        }
    }

    /** Только https и только GitHub: сами переходим по перенаправлениям и проверяем, куда. */
    private static HttpURLConnection open(String url) throws Exception {
        for (int hop = 0; hop < 5; hop++) {
            URL u = new URL(url);
            String h = u.getHost();
            if (!"https".equals(u.getProtocol()) || !(h.equals("github.com") || h.endsWith(".githubusercontent.com"))) {
                throw new Exception("bad host");
            }
            HttpURLConnection c = (HttpURLConnection) u.openConnection();
            c.setInstanceFollowRedirects(false);
            c.setConnectTimeout(15000);
            c.setReadTimeout(30000);
            int code = c.getResponseCode();
            if (code >= 300 && code < 400) {
                String loc = c.getHeaderField("Location");
                c.disconnect();
                if (loc == null) throw new Exception("no location");
                url = new URL(u, loc).toString();
                continue;
            }
            if (code != 200) {
                c.disconnect();
                throw new Exception("http " + code);
            }
            return c;
        }
        throw new Exception("too many redirects");
    }

    private static String sha256(File f) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        try (InputStream in = new FileInputStream(f)) {
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
        }
        StringBuilder sb = new StringBuilder();
        for (byte b : md.digest()) sb.append(String.format(Locale.ROOT, "%02x", b));
        return sb.toString();
    }
}
