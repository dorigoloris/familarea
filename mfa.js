(() => {
  const client = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
  const message = document.getElementById('mfa-message');
  const disabledCard = document.getElementById('mfa-disabled-card');
  const enrollCard = document.getElementById('mfa-enroll-card');
  const enabledCard = document.getElementById('mfa-enabled-card');
  const startButton = document.getElementById('mfa-start-enrollment');
  const enrollForm = document.getElementById('mfa-enroll-form');
  const enrollCode = document.getElementById('mfa-enroll-code');
  const enrollButton = document.getElementById('mfa-confirm-enrollment');
  const cancelButton = document.getElementById('mfa-cancel-enrollment');
  const qrCode = document.getElementById('mfa-qr-code');
  const disableForm = document.getElementById('mfa-disable-form');
  const disableCode = document.getElementById('mfa-disable-code');
  const disableButton = document.getElementById('mfa-disable-button');
  const signOutButton = document.getElementById('mfa-signout');
  let activeFactor = null;
  let pendingFactorId = null;

  function setMessage(text, isError = false) {
    message.textContent = text;
    message.classList.toggle('is-error', Boolean(text) && isError);
    message.classList.toggle('is-success', Boolean(text) && !isError);
  }

  function setVisible(state) {
    disabledCard.hidden = state !== 'disabled';
    enrollCard.hidden = state !== 'enroll';
    enabledCard.hidden = state !== 'enabled';
  }

  function normalizeCode(input) {
    return input.value.replace(/\s+/g, '');
  }

  function validCode(input) {
    const code = normalizeCode(input);
    if (/^\d{6}$/.test(code)) return code;
    setMessage('Inserisci il codice temporaneo di sei cifre.', true);
    input.focus();
    return null;
  }

  function setEnrollmentBusy(isBusy) {
    enrollButton.disabled = isBusy;
    cancelButton.disabled = isBusy;
  }

  function setDisableBusy(isBusy) {
    disableButton.disabled = isBusy;
  }

  function encodeSvgDataUrl(svg) {
    const bytes = new TextEncoder().encode(svg);
    let binary = '';
    bytes.forEach((byte) => { binary += String.fromCharCode(byte); });
    return `data:image/svg+xml;base64,${btoa(binary)}`;
  }

  function toQrDataUrl(qrCode) {
    const value = String(qrCode || '').trim();
    if (/^data:image\/svg\+xml(?:;[^,]*)?,/i.test(value)) return value;

    let svg = value;
    if (!/^<svg[\s>]/i.test(svg)) {
      try {
        const decoded = decodeURIComponent(value);
        if (/^<svg[\s>]/i.test(decoded.trim())) svg = decoded.trim();
      } catch {
        // Il valore puo' essere base64, che non richiede decodeURIComponent.
      }
    }
    if (/^<svg[\s>]/i.test(svg)) return encodeSvgDataUrl(svg);

    try {
      const compactBase64 = value.replace(/\s+/g, '');
      const decoded = atob(compactBase64).trim();
      if (/^<svg[\s>]/i.test(decoded)) return `data:image/svg+xml;base64,${compactBase64}`;
    } catch {
      // Non e' un SVG base64 valido: non usare URL esterni o valori ambigui.
    }
    throw new Error('Formato del codice QR non supportato.');
  }

  async function getVerifiedTotpFactor() {
    const { data, error } = await client.auth.mfa.listFactors();
    if (error) throw error;
    return (data?.totp || []).find((factor) => factor.status === 'verified') || null;
  }

  async function refreshState(successMessage = '') {
    activeFactor = await getVerifiedTotpFactor();
    pendingFactorId = null;
    enrollForm.reset();
    disableForm.reset();
    qrCode.hidden = true;
    qrCode.removeAttribute('src');
    setVisible(activeFactor ? 'enabled' : 'disabled');
    setMessage(successMessage || (activeFactor ? 'L\'autenticazione a due fattori è attiva.' : 'L\'autenticazione a due fattori non è attiva.'));
  }

  async function getChallenge(factorId) {
    const { data, error } = await client.auth.mfa.challenge({ factorId });
    if (error || !data?.id) throw error || new Error('Impossibile generare la verifica MFA.');
    return data.id;
  }

  async function verifyCode(factorId, code) {
    const challengeId = await getChallenge(factorId);
    const { error } = await client.auth.mfa.verify({ factorId, challengeId, code });
    if (error) throw error;
  }

  startButton.addEventListener('click', async () => {
    startButton.disabled = true;
    setMessage('Preparazione del codice QR...');
    try {
      const { data, error } = await client.auth.mfa.enroll({
        factorType: 'totp',
        friendlyName: 'FamilArea Authenticator'
      });
      if (error || !data?.id || !data?.totp?.qr_code) throw error || new Error('Configurazione MFA non disponibile.');
      pendingFactorId = data.id;
      qrCode.src = toQrDataUrl(data.totp.qr_code);
      qrCode.hidden = false;
      setVisible('enroll');
      setMessage('Scansiona il codice QR, quindi inserisci il codice temporaneo.', false);
      enrollCode.focus();
    } catch (error) {
      setMessage(`Impossibile avviare la configurazione MFA: ${error.message || 'riprova più tardi.'}`, true);
    } finally {
      startButton.disabled = false;
    }
  });

  cancelButton.addEventListener('click', async () => {
    setEnrollmentBusy(true);
    try {
      if (pendingFactorId) {
        const { error } = await client.auth.mfa.unenroll({ factorId: pendingFactorId });
        if (error) throw error;
      }
      pendingFactorId = null;
      await refreshState('Configurazione MFA annullata.');
    } catch (error) {
      setMessage('Impossibile annullare la configurazione MFA. Riprova oppure ricarica la pagina.', true);
    } finally {
      setEnrollmentBusy(false);
    }
  });

  enrollForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!pendingFactorId || enrollButton.disabled) return;
    const code = validCode(enrollCode);
    if (!code) return;
    setEnrollmentBusy(true);
    setMessage('Verifica del codice in corso...');
    try {
      await verifyCode(pendingFactorId, code);
      await client.auth.refreshSession();
      await refreshState('Autenticazione a due fattori attivata correttamente.');
    } catch (error) {
      setMessage(`Codice non valido o scaduto. Verifica l'orario dell'app Authenticator e riprova.`, true);
      enrollCode.select();
    } finally {
      setEnrollmentBusy(false);
    }
  });

  disableForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!activeFactor || disableButton.disabled) return;
    const code = validCode(disableCode);
    if (!code) return;
    setDisableBusy(true);
    setMessage("Conferma dell'identità in corso...");
    try {
      await verifyCode(activeFactor.id, code);
      const { error } = await client.auth.mfa.unenroll({ factorId: activeFactor.id });
      if (error) throw error;
      await client.auth.refreshSession();
      await refreshState('Autenticazione a due fattori disattivata.');
    } catch (error) {
      setMessage(`Impossibile disattivare MFA. Controlla il codice e riprova.`, true);
      disableCode.select();
    } finally {
      setDisableBusy(false);
    }
  });

  signOutButton.addEventListener('click', async () => {
    signOutButton.disabled = true;
    setMessage('Uscita in corso...');
    const { error } = await client.auth.signOut();
    if (error) {
      setMessage('Impossibile uscire in questo momento. Riprova.', true);
      signOutButton.disabled = false;
      return;
    }
    window.location.replace('login.html');
  });

  (async () => {
    const { data, error } = await client.auth.getSession();
    if (error || !data?.session) {
      window.location.replace('login.html?return_to=mfa.html');
      return;
    }
    try {
      await refreshState();
    } catch (error) {
      setMessage('Impossibile leggere lo stato MFA. Ricarica la pagina o riprova più tardi.', true);
    }
  })();
})();
