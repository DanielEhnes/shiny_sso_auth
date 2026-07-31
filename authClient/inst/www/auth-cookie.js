(function() {
  function getCookie(n) {
    var m = document.cookie.match(new RegExp('(?:^|; )' + n + '=([^;]*)'));
    return m ? decodeURIComponent(m[1]) : '';
  }
  function setCookie(n, v, maxAge, domain) {
    var s = n + '=' + encodeURIComponent(v) + '; Path=/; Max-Age=' + maxAge + '; SameSite=Lax; Secure';
    if (domain) s += '; Domain=' + domain;
    document.cookie = s;
  }
  function clearCookie(n, domain) {
    var s = n + '=; Path=/; Max-Age=0; SameSite=Lax; Secure';
    if (domain) s += '; Domain=' + domain;
    document.cookie = s;
  }

  $(document).on('shiny:sessioninitialized', function() {
    Shiny.setInputValue(window.__AUTH_INPUT_ID__ || 'auth_cookie_in', getCookie(window.__AUTH_COOKIE_NAME__ || 'app_sso'));
  });
  Shiny.addCustomMessageHandler('auth_set_cookie', function(m) {
    setCookie(m.name, m.value, m.maxAge, m.domain);
  });
  Shiny.addCustomMessageHandler('auth_clear_cookie', function(m) {
    clearCookie(m.name, m.domain);
  });
})();
