(() => {
  const allowedReturnPages = new Set([
    'dashboard.html',
    'contatto-condiviso.html',
    'invito-album.html',
    'invito-foto.html',
    'foto-condivise.html',
    'invito-collegamento.html',
    'invito-evento.html',
    'inviti-area.html',
    'mfa.html'
  ]);

  function safeReturnTo(value) {
    if (!value || value.includes('\\') || value.startsWith('//')) return 'dashboard.html';
    try {
      const url = new URL(value, window.location.origin);
      const page = url.pathname.split('/').pop();
      if (url.origin !== window.location.origin || !allowedReturnPages.has(page)) return 'dashboard.html';
      return `${page}${url.search}${url.hash}`;
    } catch {
      return 'dashboard.html';
    }
  }

  function returnToFromLocation() {
    return safeReturnTo(new URLSearchParams(window.location.search).get('return_to'));
  }

  function loginUrl(returnTo) {
    return `login.html?return_to=${encodeURIComponent(safeReturnTo(returnTo))}`;
  }

  window.FamilAreaAuthUtils = { safeReturnTo, returnToFromLocation, loginUrl };
})();
