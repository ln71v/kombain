//go:build windows

package main

import (
	_ "embed"
	"errors"
	"io"
	"log"
	"os"
	"os/exec"
	"runtime"
	"time"

	webview2 "github.com/jchv/go-webview2"
)

//go:embed ui/index.html
var interfaceHTML string

// Версию подставляет сборка на GitHub: -ldflags "-X main.version=v0.3.0"
var version = "dev"

func main() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	log.SetOutput(io.Discard)
	profile, err := os.MkdirTemp("", "kombain-webview-")
	if err != nil {
		return
	}
	defer removeProfile(profile)
	// Отдельный временный профиль, без синхронизации и сохранения форм.
	_ = os.Setenv("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", `--inprivate --disable-background-networking --disable-component-update --disable-domain-reliability --disable-sync --disable-breakpad --disable-features=AutofillServerCommunication,PasswordManagerOnboarding,msSmartScreenProtection --no-first-run --no-default-browser-check --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE fonts.googleapis.com, EXCLUDE fonts.gstatic.com"`)
	w := webview2.NewWithOptions(webview2.WebViewOptions{
		Debug:         false,
		DataPath:      profile,
		AutoFocus:     true,
		WindowOptions: webview2.WindowOptions{Title: "Комбайн " + version, Width: 720, Height: 520, Center: true},
	})
	if w == nil {
		return
	} // WebView2 Runtime автоматически не устанавливаем.
	defer w.Destroy()
	w.SetSize(720, 520, webview2.HintFixed)
	a := newInstaller()
	defer a.close()
	cleanupOld()
	upd := &exeUpdater{}
	bindings := []struct {
		name string
		fn   interface{}
	}{
		{"loginServer", a.login},
		{"trustHost", a.trustHost},
		{"installBot", a.install},
		{"installerState", func() (Snapshot, error) { return a.snapshot(), nil }},
		{"retryOwner", a.retryWait},
		{"installProxy", a.installProxy},
		{"needLogin", func() (bool, error) { return a.needLogin(), nil }},
		{"openProxy", func() error {
			link, err := a.proxyLink()
			if err != nil {
				return err
			}
			// Открывает Telegram Desktop: он сам спросит «Подключить прокси?»
			return exec.Command("rundll32", "url.dll,FileProtocolHandler", link).Start()
		}},
		{"openLink", func(url string) error {
			if !linkOK.MatchString(url) {
				return errors.New("Такую ссылку не открываю.")
			}
			// t.me откроется в Telegram Desktop, если он стоит, иначе — в браузере.
			return exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
		}},
		{"readClipboard", readClipboard},
		{"exeUpdateCheck", upd.check},
		{"exeUpdateInstall", func() error { return upd.install(func() { w.Dispatch(func() { w.Terminate() }) }) }},
		{"appVersion", func() (string, error) { return version, nil }},
		{"closeWindow", func() error { w.Dispatch(func() { w.Terminate() }); return nil }},
	}
	for _, b := range bindings {
		if err := w.Bind(b.name, b.fn); err != nil {
			return
		}
	}
	w.SetHtml(interfaceHTML)
	w.Run()
}

func removeProfile(path string) {
	// Процессы WebView2 освобождают профиль немного позже закрытия окна.
	for i := 0; i < 20; i++ {
		if os.RemoveAll(path) == nil {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}
