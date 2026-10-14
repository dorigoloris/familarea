const SUPABASE_URL = 'https://dqdmevxtdrefiqggtirh.supabase.co';
const SUPABASE_KEY = 'sb_publishable_S11fyDqQ_RLWQj_jUMiPwQ_Usfj328M';

// La site key Turnstile è pubblica. Lasciare la protezione disattivata finché
// la secret key non è configurata anche in Supabase Auth.
window.FamilAreaCaptchaConfig = Object.freeze({
  enabled: true,
  provider: 'turnstile',
  siteKey: '0x4AAAAAAFWXuJIm9a4LHWbk'
});

// Il controllo MFA resta lato client: Supabase Auth determina l'AAL della
// sessione e questa guardia impedisce di visualizzare le pagine protette
// finche' un fattore TOTP registrato non e' stato verificato.
(() => {
  const page = window.location.pathname.split('/').pop() || 'index.html';
  const exemptPages = new Set([
    'index.html', 'login.html', 'registrati.html', 'recupera-password.html',
    'nuova-password.html', 'contatto-condiviso.html', 'invito-evento.html',
    'mfa.html', 'mfa-verifica.html'
  ]);

  function safeReturnTo(value) {
    if (!value || value.includes('\\') || value.startsWith('//')) return 'dashboard.html';
    try {
      const url = new URL(value, window.location.origin);
      const targetPage = url.pathname.split('/').pop();
      if (!targetPage || url.origin !== window.location.origin || exemptPages.has(targetPage)) return 'dashboard.html';
      return `${targetPage}${url.search}${url.hash}`;
    } catch {
      return 'dashboard.html';
    }
  }

  function currentPath() {
    return `${page}${window.location.search}${window.location.hash}`;
  }

  async function requireAssurance() {
    if (exemptPages.has(page) || !window.supabase) return { required: false, passed: true };
    document.documentElement.classList.add('fa-mfa-pending');
    const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
    const { data: sessionData, error: sessionError } = await client.auth.getSession();
    if (sessionError || !sessionData?.session) {
      window.location.replace(`login.html?return_to=${encodeURIComponent(safeReturnTo(currentPath()))}`);
      return { required: false, passed: false, error: sessionError || null };
    }

    const { data, error } = await client.auth.mfa.getAuthenticatorAssuranceLevel();
    if (error) {
      window.location.replace(`mfa-verifica.html?return_to=${encodeURIComponent(currentPath())}&reason=check`);
      return { required: true, passed: false, error };
    }
    if (data?.currentLevel === 'aal1' && data?.nextLevel === 'aal2') {
      window.location.replace(`mfa-verifica.html?return_to=${encodeURIComponent(currentPath())}`);
      return { required: true, passed: false };
    }

    document.documentElement.classList.remove('fa-mfa-pending');
    return { required: false, passed: true };
  }

  window.FamilAreaMfaGuard = Object.freeze({
    ready: requireAssurance(),
    safeReturnTo,
    currentPath
  });
})();
