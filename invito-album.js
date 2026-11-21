const albumInviteClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const albumInviteTokenStorageKey = 'familarea:album-invite-token';
const albumInviteAuthResumeStorageKey = 'familarea:album-invite-auth-resume';
const albumInviteResumeParameter = 'album_invite_resume';
// Enabled only after the activation SQL patch and the tested recipient flow are deployed.
const albumInviteEnabled = true;
const albumInviteMessage = document.getElementById('album-invite-message');
const albumInviteAuth = document.getElementById('album-invite-auth');
const albumInviteResponse = document.getElementById('album-invite-response');
const albumInviteComplete = document.getElementById('album-invite-complete');
const albumInviteRecovery = document.getElementById('album-invite-recovery');
const albumInviteRecipient = document.getElementById('album-invite-recipient');
const albumInviteAlbum = document.getElementById('album-invite-album');
const albumInviteSender = document.getElementById('album-invite-sender');
const albumInviteCover = document.getElementById('album-invite-cover');
const albumInviteCoverImage = document.getElementById('album-invite-cover-image');
const albumInviteCoverPlaceholder = document.getElementById('album-invite-cover-placeholder');
const albumInviteAccept = document.getElementById('album-invite-accept');
const albumInviteDecline = document.getElementById('album-invite-decline');
const albumInviteSwitchAccount = document.getElementById('album-invite-switch-account');

let responsePending = false;
let inviteRecipientEmail = '';
let inviteCoverObjectUrl = '';
let albumInviteToken = '';
const inviteCoverMimeTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);

function validToken(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value);
}

function validResumeNonce(value) {
  return typeof value === 'string' && /^[0-9a-f]{32}$/i.test(value);
}

function createInviteResumeNonce() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function removeInviteToken() {
  albumInviteToken = '';
  try {
    window.sessionStorage.removeItem(albumInviteTokenStorageKey);
    window.sessionStorage.removeItem(albumInviteAuthResumeStorageKey);
  } catch {
    // Il token resta soltanto nella memoria della pagina quando sessionStorage non è disponibile.
  }
  try {
    delete window.__familareaAlbumInviteToken;
  } catch {
    window.__familareaAlbumInviteToken = undefined;
  }
}

function takeInviteAuthReturn() {
  const url = new URL(window.location.href);
  const resumeNonce = url.searchParams.get(albumInviteResumeParameter);
  if (resumeNonce !== null) {
    url.searchParams.delete(albumInviteResumeParameter);
    window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`);
  }
  if (!validResumeNonce(resumeNonce)) return false;
  try {
    const storedNonce = window.sessionStorage.getItem(albumInviteAuthResumeStorageKey) || '';
    window.sessionStorage.removeItem(albumInviteAuthResumeStorageKey);
    return storedNonce === resumeNonce;
  } catch {
    return false;
  }
}

function readInviteToken() {
  const tokenFromUrl = window.__familareaAlbumInviteToken;
  const cameFromInviteUrl = window.__familareaAlbumInviteTokenFromUrl === true;
  const returnedFromAuthentication = takeInviteAuthReturn();
  try {
    delete window.__familareaAlbumInviteToken;
    delete window.__familareaAlbumInviteTokenFromUrl;
  } catch {
    window.__familareaAlbumInviteToken = undefined;
    window.__familareaAlbumInviteTokenFromUrl = undefined;
  }
  if (cameFromInviteUrl && validToken(tokenFromUrl)) return tokenFromUrl;
  if (!returnedFromAuthentication) {
    removeInviteToken();
    return '';
  }
  try {
    const token = window.sessionStorage.getItem(albumInviteTokenStorageKey) || '';
    if (validToken(token)) return token;
  } catch {
    // Senza sessionStorage non è possibile riprendere in sicurezza dopo l'autenticazione.
  }
  removeInviteToken();
  return '';
}

function configureInviteAuthLinks(returnTo = 'invito-album.html') {
  document.getElementById('album-invite-login').href = window.FamilAreaAuthUtils.loginUrl(returnTo);
  document.getElementById('album-invite-register').href = `registrati.html?return_to=${encodeURIComponent(window.FamilAreaAuthUtils.safeReturnTo(returnTo))}`;
}

function prepareInviteAuthenticationReturn() {
  if (!validToken(albumInviteToken)) return 'invito-album.html';
  const resumeNonce = createInviteResumeNonce();
  try {
    window.sessionStorage.setItem(albumInviteTokenStorageKey, albumInviteToken);
    window.sessionStorage.setItem(albumInviteAuthResumeStorageKey, resumeNonce);
    return `invito-album.html?${albumInviteResumeParameter}=${encodeURIComponent(resumeNonce)}`;
  } catch {
    removeInviteToken();
    return 'invito-album.html';
  }
}

function configureInviteAuthenticationReturn() {
  configureInviteAuthLinks(prepareInviteAuthenticationReturn());
}

function clearInviteToken() {
  removeInviteToken();
}

function sharedAlbumHref(collaborationId) {
  return `timeline.html?${new URLSearchParams({
    type: 'memory',
    shared_collaboration_id: collaborationId
  })}`;
}

function normalizeEmail(value) {
  return String(value || '').trim().toLowerCase();
}

function setMessage(text, isError = false) {
  albumInviteMessage.textContent = text;
  albumInviteMessage.classList.toggle('is-error', isError);
}

function setInvitePresentation(invite) {
  const albumTitle = typeof invite?.album_title === 'string' && invite.album_title.trim()
    ? invite.album_title.trim()
    : '';
  const senderName = typeof invite?.sender_name === 'string' && invite.sender_name.trim()
    ? invite.sender_name.trim()
    : '';
  albumInviteAlbum.textContent = albumTitle || 'Un album FamilArea';
  albumInviteCoverPlaceholder.textContent = albumTitle || 'Album FamilArea';
  albumInviteSender.textContent = senderName
    ? `${senderName} ti invita a visualizzare questo album.`
    : 'Accetta l’invito per visualizzare questo album condiviso con te.';
  albumInviteSender.hidden = !senderName;
  albumInviteCover.setAttribute('aria-label', albumTitle ? `Copertina dell’album ${albumTitle}` : 'Copertina dell’album');
}

function showCoverPlaceholder() {
  if (inviteCoverObjectUrl) URL.revokeObjectURL(inviteCoverObjectUrl);
  inviteCoverObjectUrl = '';
  albumInviteCoverImage.removeAttribute('src');
  albumInviteCoverImage.hidden = true;
  albumInviteCoverPlaceholder.hidden = false;
}

async function loadInviteCover(hasCover, mimeType) {
  showCoverPlaceholder();
  if (!hasCover || !inviteCoverMimeTypes.has(mimeType)) return;
  try {
    const { data, error } = await albumInviteClient.functions.invoke('memory-share-invitation-cover', {
      body: { token: albumInviteToken }
    });
    if (error || !(data instanceof Blob) || !data.size) return;
    inviteCoverObjectUrl = URL.createObjectURL(new Blob([data], { type: mimeType }));
    albumInviteCoverImage.onload = () => {
      albumInviteCoverPlaceholder.hidden = true;
      albumInviteCoverImage.hidden = false;
    };
    albumInviteCoverImage.onerror = showCoverPlaceholder;
    albumInviteCoverImage.src = inviteCoverObjectUrl;
  } catch (_) {
    showCoverPlaceholder();
  }
}

function setResponseBusy(busy) {
  responsePending = busy;
  albumInviteAccept.disabled = busy || !albumInviteEnabled;
  albumInviteDecline.disabled = busy || !albumInviteEnabled;
}

function unavailableMessage(error) {
  const reason = String(error?.message || '').toLowerCase();
  if (reason.includes('verified recipient email')) return 'Verifica l’indirizzo email del tuo account prima di rispondere all’invito.';
  if (reason.includes('expired')) return 'Questo invito è scaduto.';
  return 'Questo invito non è disponibile: potrebbe essere scaduto, annullato, revocato, già gestito o non valido.';
}

function showWrongAccountMessage() {
  configureInviteAuthenticationReturn();
  albumInviteResponse.hidden = true;
  albumInviteAuth.hidden = false;
  albumInviteSwitchAccount.hidden = false;
  setMessage(`Questo invito è destinato a ${inviteRecipientEmail}. Accedi con l’account verificato che usa esattamente questo indirizzo.`, true);
}

function showRecovery() {
  albumInviteRecovery.hidden = false;
}

async function switchAccount() {
  albumInviteSwitchAccount.disabled = true;
  await albumInviteClient.auth.signOut();
  window.location.replace(document.getElementById('album-invite-login').href);
}

async function loadInvite() {
  albumInviteToken = readInviteToken();
  if (!validToken(albumInviteToken)) {
    setMessage('Il collegamento dell’invito non è valido.', true);
    showRecovery();
    return;
  }

  configureInviteAuthenticationReturn();

  if (!albumInviteEnabled) {
    setMessage('Gli inviti Album via email sono in preparazione. Nessuna risposta può essere inviata al momento.');
    return;
  }

  const { data: sessionData, error: sessionError } = await albumInviteClient.auth.getSession();
  if (sessionError || !sessionData?.session) {
    setMessage('');
    albumInviteAuth.hidden = false;
    return;
  }

  const { data, error } = await albumInviteClient.rpc('get_memory_share_invitation_context', { p_token: albumInviteToken });
  if (error || !data?.recipient_email) {
    setMessage(unavailableMessage(error), true);
    showRecovery();
    return;
  }

  setInvitePresentation(data);
  inviteRecipientEmail = normalizeEmail(data.recipient_email);
  const { data: userData, error: userError } = await albumInviteClient.auth.getUser();
  const authenticatedEmail = normalizeEmail(userData?.user?.email);
  if (userError || !authenticatedEmail || authenticatedEmail !== inviteRecipientEmail) {
    showWrongAccountMessage();
    return;
  }

  void loadInviteCover(data.has_cover === true, data.cover_mime_type);
  albumInviteRecipient.textContent = `Invito inviato a: ${inviteRecipientEmail}`;
  albumInviteResponse.hidden = false;
  setResponseBusy(false);
  setMessage('');
}

async function respondToInvite(rpcName, successMessage) {
  if (!albumInviteEnabled || responsePending || !validToken(albumInviteToken)) return;
  setResponseBusy(true);
  setMessage('Registrazione della risposta...');
  const { data, error } = await albumInviteClient.rpc(rpcName, { p_token: albumInviteToken });
  if (error) {
    setResponseBusy(false);
    setMessage(unavailableMessage(error), true);
    return;
  }
  albumInviteResponse.hidden = true;
  clearInviteToken();
  if (rpcName === 'accept_my_memory_share_invitation') {
    if (typeof data === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(data)) {
      setMessage('Invito accettato. Apertura dell’album...');
      window.location.replace(sharedAlbumHref(data));
      return;
    }
    albumInviteComplete.hidden = false;
  }
  setMessage(successMessage);
}

albumInviteAccept.addEventListener('click', () => void respondToInvite('accept_my_memory_share_invitation', 'Invito accettato.'));
albumInviteDecline.addEventListener('click', () => void respondToInvite('decline_my_memory_share_invitation', 'Invito rifiutato.'));
albumInviteSwitchAccount.addEventListener('click', () => void switchAccount());
window.addEventListener('pagehide', showCoverPlaceholder, { once: true });
void loadInvite();
