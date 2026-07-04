// Click-to-copy for the Connect QGIS page. Each copy button lives in the same
// table cell as the value it copies (a `.gtt-copy-value` element), so there is
// a single source of truth and no id wiring to keep in sync.
(function () {
  'use strict';

  function flash(button, text) {
    var original = button.getAttribute('data-label-copy');
    button.textContent = text;
    button.classList.add('gtt-copy--done');
    window.setTimeout(function () {
      button.textContent = original;
      button.classList.remove('gtt-copy--done');
    }, 1500);
  }

  // Fallback for the rare non-secure context where navigator.clipboard is
  // absent (localhost and https are secure, so this seldom runs).
  function legacyCopy(value) {
    var area = document.createElement('textarea');
    area.value = value;
    area.setAttribute('readonly', '');
    area.style.position = 'absolute';
    area.style.left = '-9999px';
    document.body.appendChild(area);
    area.select();
    try {
      document.execCommand('copy');
    } finally {
      document.body.removeChild(area);
    }
  }

  function copyValue(button) {
    var cell = button.closest('td');
    var source = cell && cell.querySelector('.gtt-copy-value');
    if (!source) {
      return;
    }
    var value = source.textContent.trim();
    var done = function () {
      flash(button, button.getAttribute('data-label-copied'));
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(value).then(done, function () {
        legacyCopy(value);
        done();
      });
    } else {
      legacyCopy(value);
      done();
    }
  }

  document.addEventListener('DOMContentLoaded', function () {
    var buttons = document.querySelectorAll('.gtt-copy');
    Array.prototype.forEach.call(buttons, function (button) {
      button.addEventListener('click', function () {
        copyValue(button);
      });
    });
  });
})();
