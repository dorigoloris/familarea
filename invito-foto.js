const photoInviteClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const photoInviteTokenStorageKey = 'familarea:memory-photo-share-invite-token';
const photoInviteAuthResumeStorageKey = 'familarea:memory-photo-share-invite-auth-resume';
const photoInviteResumeParameter = 'photo_invite_resume';
const photoInviteMessage = document.getElementById('photo-invite-message');
const photoInviteAuth = document.getElementById('photo-invite-auth');
const photoInviteResponse = document.getElementById('photo-invite-response');
const photoInviteComplete = document.getElementById('photo-invite-complete');
const photoInviteLogin = document.getElementById('photo-invite-login');
const photoInviteRegister = document.getElementById('photo-invite-register');
const photoInviteSwitchAccount = document.getElementById('photo-invite-switch-account');
const photoInviteAccept = document.getElementById('photo-invite-accept');
const photoInviteDecline = document.getElementById('photo-invite-decline');

let photoInviteToken = '';
let photoInviteResponsePending = false;

function isPhotoInviteToken(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value);
}

function isPhotoInviteResumeNonce(value) {
  return typeof value === 'string' && /^[0-9a-f]{32}$/i.test(value);
}

function isUuid(value) {
  return typeof value === 'string'
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function setPhotoInviteMessage(message, isError = false) {
  photoInviteMessage.textContent = message;
  photoInviteMessage.classList.toggle('fa-v2-status--error', isError);
}

function setPhotoInviteButtonsDisabled(disabled) {
  photoInviteAccept.disabled = disabled;
  photoInviteDecline.disabled = disabled;
}

function removePhotoInviteToken() {
  photoInviteToken = '';
  try {
    window.sessionStorage.removeItem(photoInviteTokenStorageKey);
    window.sessionStorage.removeItem(photoInviteAuthResumeStorageKey);
  } catch {
    // Il token resta soltanto nella memoria della pagina quando sessionStorage non è disponibile.
  }
  try {
    delete window.__familareaMemoryPhotoInviteToken;
  } catch {
    window.__familareaMemoryPhotoInviteToken = undefined;
  }
}

function createPhotoInviteResumeNonce() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function takePhotoInviteAuthReturn() {
  const url = new URL(window.location.href);
  const resumeNonce = url.searchParams.get(photoInviteResumeParameter);

  if (resumeNonce !== null) {
    url.searchParams.delete(photoInviteResumeParameter);
    window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`);
  }

  if (!isPhotoInviteResumeNonce(resumeNonce)) return false;

  try {
    const storedNonce = window.sessionStorage.getItem(photoInviteAuthResumeStorageKey) || '';
    window.sessionStorage.removeItem(photoInviteAuthResumeStorageKey);
    return storedNonce === resumeNonce;
  } catch {
    return false;
  }
}

function readPhotoInviteToken() {
  const tokenFromUrl = window.__familareaMemoryPhotoInviteToken;
  const cameFromInviteUrl = window.__familareaMemoryPhotoInviteTokenFromUrl === true;
  const returnedFromAuthentication = takePhotoInviteAuthReturn();

  try {
    delete window.__familareaMemoryPhotoInviteToken;
    delete window.__familareaMemoryPhotoInviteTokenFromUrl;
  } catch {
    window.__familareaMemoryPhotoInviteToken = undefined;
    window.__familareaMemoryPhotoInviteTokenFromUrl = undefined;
  }

  if (cameFromInviteUrl && isPhotoInviteToken(tokenFromUrl)) return tokenFromUrl;

  if (!returnedFromAuthentication) {
    removePhotoInviteToken();
    return '';
  }

  try {
    const token = window.sessionStorage.getItem(photoInviteTokenStorageKey) || '';
    if (isPhotoInviteToken(token)) return token;
  } catch {
    // Senza sessionStorage non è possibile riprendere in sicurezza dopo una navigazione di autenticazione.
  }

  removePhotoInviteToken();
  return '';
}

function configurePhotoInviteAuthLinks(returnTo = 'invito-foto.html') {
  photoInviteLogin.href = FamilAreaAuthUtils.loginUrl(returnTo);
  photoInviteRegister.href = `registrati.html?return_to=${encodeURIComponent(FamilAreaAuthUtils.safeReturnTo(returnTo))}`;
}

function preparePhotoInviteAuthenticationReturn() {
  if (!isPhotoInviteToken(photoInviteToken)) return 'invito-foto.html';

  const resumeNonce = createPhotoInviteResumeNonce();
  try {
    window.sessionStorage.setItem(photoInviteTokenStorageKey, photoInviteToken);
    window.sessionStorage.setItem(photoInviteAuthResumeStorageKey, resumeNonce);
    return `invito-foto.html?${photoInviteResumeParameter}=${encodeURIComponent(resumeNonce)}`;
  } catch {
    removePhotoInviteToken();
    return 'invito-foto.html';
  }
}

function configurePhotoInviteAuthenticationReturn() {
  configurePhotoInviteAuthLinks(preparePhotoInviteAuthenticationReturn());
}

function showPhotoInviteAuthentication(message, signedIn = false) {
  photoInviteResponse.hidden = true;
  photoInviteComplete.hidden = true;
  photoInviteAuth.hidden = false;
  photoInviteSwitchAccount.hidden = !signedIn;
  setPhotoInviteMessage(message, true);
}

function showPhotoInviteUnavailable() {
  if (isPhotoInviteToken(photoInviteToken)) {
    configurePhotoInviteAuthenticationReturn();
  } else {
    configurePhotoInviteAuthLinks();
  }
  photoInviteResponse.hidden = true;
  photoInviteComplete.hidden = true;
  photoInviteAuth.hidden = false;
  photoInviteSwitchAccount.hidden = false;
  setPhotoInviteMessage('Questo invito non è disponibile. Verifica di usare l’indirizzo email invitato e che sia stato verificato.', true);
}

async function loadPhotoInvite() {
  photoInviteToken = readPhotoInviteToken();

  if (!photoInviteToken) {
    photoInviteAuth.hidden = true;
    setPhotoInviteMessage('Invito non valido o non più disponibile.', true);
    return;
  }

  const { data: { session } } = await photoInviteClient.auth.getSession();
  if (!session) {
    configurePhotoInviteAuthenticationReturn();
    showPhotoInviteAuthentication('Accedi o registrati per verificare l’invito.');
    return;
  }

  const { data: { user }, error: userError } = await photoInviteClient.auth.getUser();
  if (userError || !user) {
    configurePhotoInviteAuthenticationReturn();
    showPhotoInviteAuthentication('La sessione non è più valida. Accedi di nuovo.');
    return;
  }

  const { data, error } = await photoInviteClient.rpc('get_memory_photo_share_invitation_context', {
    p_token: photoInviteToken,
  });

  if (error) {
    showPhotoInviteUnavailable();
    return;
  }

  if (!data || !isUuid(data.share_id)) {
    removePhotoInviteToken();
    showPhotoInviteUnavailable();
    return;
  }

  if (data.status === 'accepted') {
    removePhotoInviteToken();
    window.location.replace(`foto-condivise.html?share=${encodeURIComponent(data.share_id)}`);
    return;
  }

  if (data.status !== 'pending') {
    removePhotoInviteToken();
    showPhotoInviteUnavailable();
    return;
  }

  photoInviteAuth.hidden = true;
  photoInviteComplete.hidden = true;
  photoInviteResponse.hidden = false;
  setPhotoInviteMessage('Invito pronto: puoi accettare o rifiutare.');
}

async function acceptPhotoInvite() {
  if (photoInviteResponsePending || !photoInviteToken) return;

  photoInviteResponsePending = true;
  setPhotoInviteButtonsDisabled(true);
  setPhotoInviteMessage('Accettazione dell’invito in corso...');

  const { data, error } = await photoInviteClient.rpc('accept_my_memory_photo_share', {
    p_token: photoInviteToken,
  });

  if (error) {
    photoInviteResponsePending = false;
    setPhotoInviteButtonsDisabled(false);
    showPhotoInviteUnavailable();
    return;
  }

  if (!isUuid(data)) {
    removePhotoInviteToken();
    photoInviteResponse.hidden = true;
    setPhotoInviteMessage('L’invito non può più essere accettato.', true);
    return;
  }

  removePhotoInviteToken();
  window.location.replace(`foto-condivise.html?share=${encodeURIComponent(data)}`);
}

async function declinePhotoInvite() {
  if (photoInviteResponsePending || !photoInviteToken) return;

  photoInviteResponsePending = true;
  setPhotoInviteButtonsDisabled(true);
  setPhotoInviteMessage('Rifiuto dell’invito in corso...');

  const { error } = await photoInviteClient.rpc('decline_my_memory_photo_share', {
    p_token: photoInviteToken,
  });

  if (error) {
    photoInviteResponsePending = false;
    setPhotoInviteButtonsDisabled(false);
    showPhotoInviteUnavailable();
    return;
  }

  removePhotoInviteToken();
  photoInviteResponse.hidden = true;
  photoInviteComplete.hidden = false;
  setPhotoInviteMessage('Invito rifiutato.');
}

photoInviteAccept.addEventListener('click', () => {
  void acceptPhotoInvite();
});

photoInviteDecline.addEventListener('click', () => {
  void declinePhotoInvite();
});

photoInviteSwitchAccount.addEventListener('click', async () => {
  photoInviteSwitchAccount.disabled = true;
  configurePhotoInviteAuthenticationReturn();
  const loginHref = photoInviteLogin.href;
  await photoInviteClient.auth.signOut();
  window.location.replace(loginHref);
});

void loadPhotoInvite();
