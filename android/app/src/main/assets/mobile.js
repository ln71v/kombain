// Мост: интерфейс kombain-start.exe вызывает window.<шаг>(), здесь эти шаги уходят в Go-ядро
// (та же логика, что у exe) через KombainNative. Плюс правка слов «компьютер» → «телефон».
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
  ['loginServer', 'installBot', 'installerState', 'retryOwner', 'installProxy',
    'needLogin', 'openProxy', 'appVersion', 'closeWindow'].forEach(function (n) {
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
      var st = d.getAttribute('style') || '';
      if (/display:\s*grid/.test(st) && /grid-template-columns/.test(st)) d.style.gridTemplateColumns = '1fr';
      if (/display:\s*flex/.test(st) && !/flex-direction:\s*column/.test(st) && d.children.length > 1 &&
          !d.classList.contains('kb-col') && (d.getBoundingClientRect().right > max + 1 || d.scrollWidth > d.clientWidth + 1)) d.classList.add('kb-col');
    });
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
      if (t.indexOf('На этом компьютере') === 0) d.innerHTML = '<b>На этом телефоне:</b> жми «Открыть в Telegram» внизу → «Подключить прокси».';
      else if (t.indexOf('На телефоне:') === 0) d.innerHTML = '<b>На другом телефоне:</b> наведи камеру на QR-код → «Открыть в Telegram» → «Подключить прокси».';
    });
    var open = el('proxy-open'), openErr = el('open-error');
    if (open) open.onclick = function () {
      openErr.hidden = true;
      window.openProxy().catch(function (e) { openErr.textContent = e.message; openErr.hidden = false; });
    };

    // Имя бота — нажал, открылся бот в Telegram.
    var bot = el('bot-name');
    if (bot) bot.addEventListener('click', function () {
      var name = bot.textContent.replace(/^@/, '').trim();
      if (name) call('openBot', [name]).catch(function () {});
    });
  });
})();
