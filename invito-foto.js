const photoInviteClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const photoInviteTokenStorageKey = 'familarea:memory-photo-share-invite-token';
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
  } catch {
    // Il token resta soltanto nella memoria della pagina quando sessionStorage non Ã¨ disponibile.
  }
  try {
    delete window.__familareaMemoryPhotoInviteToken;
  } catch {
    window.__familareaMemoryPhotoInviteToken = undefined;
  }
}

function readPhotoInviteToken() {
  let token = '';
  try {
    token = window.sessionStorage.getItem(photoInviteTokenStorageKey) || '';
  } catch {
    // Fallback limitato alla vita della pagina, impostato dallo script inline prima delle risorse esterne.
  }

  if (!token && typeof window.__familareaMemoryPhotoInviteToken === 'string') {
    token = window.__familareaMemoryPhotoInviteToken;
  }

  try {
    delete window.__familareaMemoryPhotoInviteToken;
  } catch {
    window.__familareaMemoryPhotoInviteToken = undefined;
  }

  return isPhotoInviteToken(token) ? token : '';
}

function configurePhotoInviteAuthLinks() {
  const returnTo = 'invito-foto.html';
  photoInviteLogin.href = FamilAreaAuthUtils.loginUrl(returnTo);
  photoInviteRegister.href = `registrati.html?return_to=${encodeURIComponent(FamilAreaAuthUtils.safeReturnTo(returnTo))}`;
}

function showPhotoInviteAuthentication(message, signedIn = false) {
  photoInviteResponse.hidden = true;
  photoInviteComplete.hidden = true;
  photoInviteAuth.hidden = false;
  photoInviteSwitchAccount.hidden = !signedIn;
  setPhotoInviteMessage(message, true);
}

function showPhotoInviteUnavailable() {
  photoInviteResponse.hidden = true;
  photoInviteComplete.hidden = true;
  photoInviteAuth.hidden = false;
  photoInviteSwitchAccount.hidden = false;
  setPhotoInviteMessage('Questo invito non Ã¨ disponibile. Verifica di usare lâ€™indirizzo email invitato e che sia stato verificato.', true);
}

async function loadPhotoInvite() {
  configurePhotoInviteAuthLinks();
  photoInviteToken = readPhotoInviteToken();

  if (!photoInviteToken) {
    photoInviteAuth.hidden = true;
    setPhotoInviteMessage('Invito non valido o non piÃ¹ disponibile.', true);
    return;
  }

  const { data: { session } } = await photoInviteClient.auth.getSession();
  if (!session) {
    showPhotoInviteAuthentication('Accedi o registrati per verificare lâ€™invito.');
    return;
  }

  const { data: { user }, error: userError } = await photoInviteClient.auth.getUser();
  if (userError || !user) {
    showPhotoInviteAuthentication('La sessione non Ã¨ piÃ¹ valida. Accedi di nuovo.');
    return;
  }

  const { data, error } = await photoInviteClient.rpc('get_memory_photo_share_invitation_context', {
    p_token: photoInviteToken,
  });

  if (error || !data || !isUuid(data.share_id)) {
    showPhotoInviteUnavailable();
    return;
  }

  if (data.status === 'accepted') {
    removePhotoInviteToken();
    window.location.replace(`foto-condivise.html?share=${encodeURIComponent(data.share_id)}`);
    return;
  }

  if (data.status !== 'pending') {
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
  setPhotoInviteMessage('Accettazione dellâ€™invito in corso...');

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
    setPhotoInviteMessage('Lâ€™invito non puÃ² piÃ¹ essere accettato.', true);
    return;
  }

  removePhotoInviteToken();
  window.location.replace(`foto-condivise.html?share=${encodeURIComponent(data)}`);
}

async function declinePhotoInvite() {
  if (photoInviteResponsePending || !photoInviteToken) return;

  photoInviteResponsePending = true;
  setPhotoInviteButtonsDisabled(true);
  setPhotoInviteMessage('Rifiuto dellâ€™invito in corso...');

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
  await photoInviteClient.auth.signOut();
  window.location.replace(photoInviteLogin.href);
});

void loadPhotoInvite();