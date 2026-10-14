(() => {
  const client = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
  const form = document.getElementById('mfa-verify-form');
  const message = document.getElementById('mfa-verify-message');
  const codeInput = document.getElementById('mfa-verify-code');
  const verifyButton = document.getElementById('mfa-verify-button');
  const signOutButton = document.getElementById('mfa-verify-signout');
  const reason = new URLSearchParams(window.location.search).get('reason');
  const returnTo = window.FamilAreaMfaGuard.safeReturnTo(new URLSearchParams(window.location.search).get('return_to'));
  let factor = null;

  function setMessage(text, isError = false) {
    message.textContent = text;
    message.classList.toggle('is-error', Boolean(text) && isError);
  }

  function setBusy(isBusy) {
    verifyButton.disabled = isBusy;
    signOutButton.disabled = isBusy;
  }

  function redirectToLogin() {
    window.location.replace(`login.html?return_to=${encodeURIComponent(returnTo)}`);
  }

  async function loadFactor() {
    const { data: sessionData, error: sessionError } = await client.auth.getSession();
    if (sessionError || !sessionData?.session) {
      redirectToLogin();
      return;
    }
    const { data: assurance, error: assuranceError } = await client.auth.mfa.getAuthenticatorAssuranceLevel();
    if (assuranceError) {
      setMessage('Impossibile verificare lo stato di sicurezza. Ricarica la pagina.', true);
      return;
    }
    if (assurance?.currentLevel === 'aal2' || assurance?.nextLevel !== 'aal2') {
      window.location.replace(returnTo);
      return;
    }
    const { data, error } = await client.auth.mfa.listFactors();
    if (error) {
      setMessage('Impossibile preparare la verifica MFA. Ricarica la pagina.', true);
      return;
    }
    factor = (data?.totp || []).find((item) => item.status === 'verified') || null;
    if (!factor) {
      setMessage('Non è disponibile un fattore MFA valido. Esci e contatta l’assistenza per il recupero dell’accesso.', true);
      signOutButton.hidden = false;
      return;
    }
    form.hidden = false;
    setMessage(reason === 'check' ? 'Completa la verifica MFA per continuare.' : '');
    codeInput.focus();
  }

  signOutButton.addEventListener('click', async () => {
    setBusy(true);
    const { error } = await client.auth.signOut();
    if (error) {
      setMessage('Impossibile uscire in questo momento. Riprova.', true);
      setBusy(false);
      return;
    }
    window.location.replace('login.html');
  });

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!factor || verifyButton.disabled) return;
    const code = codeInput.value.replace(/\s+/g, '');
    if (!/^\d{6}$/.test(code)) {
      setMessage('Inserisci il codice temporaneo di sei cifre.', true);
      codeInput.focus();
      return;
    }
    setBusy(true);
    setMessage('Verifica del codice in corso...');
    try {
      const { data: challenge, error: challengeError } = await client.auth.mfa.challenge({ factorId: factor.id });
      if (challengeError || !challenge?.id) throw challengeError || new Error('Challenge MFA non disponibile.');
      const { error: verifyError } = await client.auth.mfa.verify({ factorId: factor.id, challengeId: challenge.id, code });
      if (verifyError) throw verifyError;
      window.location.replace(returnTo);
    } catch (error) {
      setMessage('Codice non valido, scaduto o verifica non disponibile. Riprova.', true);
      codeInput.select();
      setBusy(false);
    }
  });

  loadFactor().catch(() => setMessage('Impossibile avviare la verifica MFA. Ricarica la pagina.', true));
})();
