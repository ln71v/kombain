package io.github.ln71v.kombain;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileNotFoundException;

/**
 * Отдаёт окну установки Android ровно один файл — скачанное обновление (только чтение).
 * Нужен для установки «по-старому» (Xiaomi/Redmi/POCO): ACTION_VIEW + content://.
 * Наружу не открыт: доступ даётся разово флагом FLAG_GRANT_READ_URI_PERMISSION.
 */
public final class ApkProvider extends ContentProvider {
    static final String AUTHORITY = "io.github.ln71v.kombain.apk";
    static final String MIME = "application/vnd.android.package-archive";
    static final String NAME = "kombain-update.apk";
    static final Uri URI = Uri.parse("content://" + AUTHORITY + "/" + NAME);

    /** Где лежит скачанное обновление. Тот же путь использует Updater. */
    static File file(android.content.Context c) {
        return new File(new File(c.getCacheDir(), "update"), NAME);
    }

    private File mine(Uri uri) throws FileNotFoundException {
        if (uri == null || !AUTHORITY.equals(uri.getAuthority()) || !("/" + NAME).equals(uri.getPath())) {
            throw new FileNotFoundException("нет такого файла");
        }
        File f = file(getContext());
        if (!f.isFile()) throw new FileNotFoundException("обновление не скачано");
        return f;
    }

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (mode == null || !mode.equals("r")) throw new SecurityException("только чтение");
        return ParcelFileDescriptor.open(mine(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override
    public String getType(Uri uri) {
        return MIME;
    }

    /** Окно установки спрашивает имя и размер файла — отвечаем только на это. */
    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        File f;
        try {
            f = mine(uri);
        } catch (FileNotFoundException e) {
            return null;
        }
        String[] cols = projection != null ? projection : new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE};
        MatrixCursor c = new MatrixCursor(cols, 1);
        Object[] row = new Object[cols.length];
        for (int i = 0; i < cols.length; i++) {
            if (OpenableColumns.DISPLAY_NAME.equals(cols[i])) row[i] = NAME;
            else if (OpenableColumns.SIZE.equals(cols[i])) row[i] = f.length();
        }
        c.addRow(row);
        return c;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException();
    }

    @Override
    public int delete(Uri uri, String selection, String[] args) {
        throw new UnsupportedOperationException();
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] args) {
        throw new UnsupportedOperationException();
    }
}
