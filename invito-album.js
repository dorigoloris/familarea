const albumInviteClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const albumInviteTokenStoragePrefix = 'familarea:album-invite-token:';
const albumInviteParams = new URLSearchParams(window.location.search);
const albumInviteTokenFromQuery = albumInviteParams.get('token') || '';
const albumInviteResumeFromQuery = albumInviteParams.get('invite') || '';
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
let albumInviteResumeId = /^[0-9a-f-]{36}$/i.test(albumInviteResumeFromQuery) ? albumInviteResumeFromQuery : '';
const inviteCoverMimeTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);

function validToken(value) {
  return /^[A-Za-z0-9_-]{32,128}$/.test(value);
}

function inviteTokenStorageKey() {
  return albumInviteResumeId ? `${albumInviteTokenStoragePrefix}${albumInviteResumeId}` : '';
}

function createInviteResumeId() {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function readInviteToken() {
  if (validToken(albumInviteTokenFromQuery)) {
    try {
      albumInviteResumeId = createInviteResumeId();
      window.sessionStorage.setItem(inviteTokenStorageKey(), albumInviteTokenFromQuery);
      const url = new URL(window.location.href);
      url.searchParams.delete('token');
      url.searchParams.set('invite', albumInviteResumeId);
      window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`);
      return albumInviteTokenFromQuery;
    } catch {
      return albumInviteTokenFromQuery;
    }
  }
  if (albumInviteParams.has('token')) return '';
  try {
    return inviteTokenStorageKey() ? window.sessionStorage.getItem(inviteTokenStorageKey()) || '' : '';
  } catch {
    return '';
  }
}

function clearInviteToken() {
  try {
    if (inviteTokenStorageKey()) window.sessionStorage.removeItem(inviteTokenStorageKey());
  } catch {}
}

const albumInviteToken = readInviteToken();

function inviteReturnTo() {
  return albumInviteResumeId ? `invito-album.html?invite=${encodeURIComponent(albumInviteResumeId)}` : 'invito-album.html';
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
  if (!validToken(albumInviteToken)) {
    setMessage('Il collegamento dell’invito non è valido.', true);
    showRecovery();
    return;
  }

  const returnTo = inviteReturnTo();
  document.getElementById('album-invite-login').href = window.FamilAreaAuthUtils.loginUrl(returnTo);
  document.getElementById('album-invite-register').href = `registrati.html?return_to=${encodeURIComponent(window.FamilAreaAuthUtils.safeReturnTo(returnTo))}`;

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
