// Мост: интерфейс kombain-start.exe вызывает window.<шаг>(), здесь эти шаги уходят в Go-ядро
// (та же логика, что у exe) через KombainNative. Плюс правка слов «компьютер» → «телефон»
// и плашка «есть новая версия» (обновление прямо из приложения).
(function () {
  'use strict';
  var N = window.KombainNative;
  function call(name, args) {
    return new Promise(function (ok, fail) {
      setTimeout(function () {
        var r;
        try { r = JSON.parse(N.call(name, JSON.stringify(args))); }
        catch (e) { fail(new Error('Не получилось выполнить шаг. Попробуй ещё раз.')); return; }
        if (r.error) fail(new Error(r.error)); else ok(r.result);
      }, 0);
    });
  }
  ['loginServer', 'trustHost', 'installBot', 'installerState', 'retryOwner', 'installProxy',
    'needLogin', 'openProxy', 'appVersion', 'closeWindow', 'openLink', 'readClipboard'].forEach(function (n) {
    window[n] = function () { return call(n, Array.prototype.slice.call(arguments).map(String)); };
  });

  function swapText(from, to) {
    var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), n;
    while ((n = w.nextNode())) if (n.nodeValue.indexOf(from) >= 0) n.nodeValue = n.nodeValue.split(from).join(to);
  }
  function el(id) { return document.getElementById(id); }
  function fit() {
    var max = document.documentElement.clientWidth;
    document.querySelectorAll('.screen:not([hidden]) [style]').forEach(function (d) {
      if (d.id === 'digits') return; // код — своя раскладка в mobile.css
      var st = d.getAttribute('style') || '';
      if (/display:\s*grid/.test(st) && /grid-template-columns/.test(st)) d.style.gridTemplateColumns = '1fr';
      if (/display:\s*flex/.test(st) && !/flex-direction:\s*column/.test(st) && d.children.length > 1 &&
          !d.classList.contains('kb-col') && (d.getBoundingClientRect().right > max + 1 || d.scrollWidth > d.clientWidth + 1)) d.classList.add('kb-col');
    });
  }

  // ---- Обновление приложения ----
  // Комбайн сам сверяет себя с файлом на GitHub. Отличается — плашка с кнопкой «Обновить».
  function updateBox() {
    var box = el('kb-update');
    if (box) return box;
    var first = document.querySelector('#screen-1 > div > div:nth-child(2)');
    if (!first) return null;
    box = document.createElement('div');
    box.id = 'kb-update';
    box.hidden = true;
    box.innerHTML = '<div id="kb-update-text"></div><button type="button" class="primary" id="kb-update-btn">Обновить</button>' +
      '<small>Android спросит «Обновить приложение?» — жми «Обновить». Если выскочит окно Play Защиты: ' +
      '«Подробнее» → «Всё равно установить». Не нажимается (бывает на магнитолах) — Play Маркет → аватарка → ' +
      'Play Защита → шестерёнка → выключи «Проверять приложения», обнови и включи обратно.</small>';
    first.insertBefore(box, first.firstChild);
    el('kb-update-btn').onclick = function () {
      call('updateInstall', []).then(watchUpdate).catch(function (e) { setUpdate(e.message, true); });
    };
    return box;
  }
  function setUpdate(text, button) {
    var box = updateBox();
    if (!box) return;
    el('kb-update-text').textContent = text;
    el('kb-update-btn').hidden = !button;
    box.hidden = false;
  }
  var watching = false;
  function watchUpdate() {
    if (watching) return;
    watching = true;
    var tries = 0;
    (function tick() {
      call('updateState', []).then(function (s) {
        s = s || {};
        if (s.state === 'available') { setUpdate('Вышла новая версия Комбайна.', true); watching = false; return; }
        if (s.state === 'downloading') setUpdate('Качаю новую версию…', false);
        if (s.state === 'installing') { setUpdate('Открыл установку — жми «Обновить».', false); watching = false; return; }
        if (s.state === 'permission') { setUpdate('Разреши Комбайну ставить обновления: в открывшемся окне включи переключатель, вернись и жми «Обновить» ещё раз.', true); watching = false; return; }
        if (s.state === 'error') { setUpdate(s.message || 'Не получилось обновиться. Попробуй позже.', true); watching = false; return; }
        if (s.state === 'none' && tries > 0) { watching = false; return; }
        if (++tries < 120) setTimeout(tick, 1500); else watching = false;
      }).catch(function () { watching = false; });
    })();
  }

  document.addEventListener('DOMContentLoaded', function () {
    swapText('На твоём компе ничего не меняю.', 'На телефоне ничего не меняю.');
    swapText('Раздай интернет с телефона и нажми ещё раз.', 'Переключись с Wi-Fi на мобильный интернет (или наоборот) и нажми ещё раз.');

    // Широкие ряды карточек — в столбик. Проверяем каждый раз, когда открывается экран.
    if (typeof window.show === 'function') {
      var show = window.show;
      window.show = function (n) { show(n); fit(); };
    }
    window.addEventListener('resize', fit);
    fit();

    // Экран «Прокси готов»: тут кнопка открывает Telegram на этом же телефоне.
    var ready = el('tg-ready');
    if (ready) ready.querySelectorAll('div').forEach(function (d) {
      var t = d.textContent;
      if (t.indexOf('На этом компьютере') === 0) d.innerHTML = '<b>На этом телефоне:</b> жми «Открыть в Telegram ↗» внизу → «Подключить прокси».';
      else if (t.indexOf('На телефоне:') === 0) d.innerHTML = '<b>На другом телефоне:</b> наведи камеру на QR-код → «Открыть в Telegram» → «Подключить прокси».';
    });
    var open = el('proxy-open'), openErr = el('open-error');
    if (open) open.onclick = function () {
      openErr.hidden = true;
      window.openProxy().catch(function (e) { openErr.textContent = e.message; openErr.hidden = false; });
    };

    // Проверка новой версии — в фоне, окно не ждёт.
    call('updateCheck', []).then(watchUpdate).catch(function () {});
  });
})();
