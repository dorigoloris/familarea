const albumInviteClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const albumInviteTokenStorageKey = 'familarea:album-invite-token';
const albumInviteTokenFromQuery = new URLSearchParams(window.location.search).get('token') || '';
// Enabled only after the activation SQL patch and the tested recipient flow are deployed.
const albumInviteEnabled = true;
const albumInviteMessage = document.getElementById('album-invite-message');
const albumInviteAuth = document.getElementById('album-invite-auth');
const albumInviteResponse = document.getElementById('album-invite-response');
const albumInviteComplete = document.getElementById('album-invite-complete');
const albumInviteRecipient = document.getElementById('album-invite-recipient');
const albumInviteAccept = document.getElementById('album-invite-accept');
const albumInviteDecline = document.getElementById('album-invite-decline');
const albumInviteSwitchAccount = document.getElementById('album-invite-switch-account');

let responsePending = false;
let inviteRecipientEmail = '';

function validToken(value) {
  return /^[A-Za-z0-9_-]{32,128}$/.test(value);
}

function readInviteToken() {
  if (validToken(albumInviteTokenFromQuery)) {
    try {
      window.sessionStorage.setItem(albumInviteTokenStorageKey, albumInviteTokenFromQuery);
      const url = new URL(window.location.href);
      url.searchParams.delete('token');
      window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`);
      return albumInviteTokenFromQuery;
    } catch {
      return albumInviteTokenFromQuery;
    }
  }
  try {
    return window.sessionStorage.getItem(albumInviteTokenStorageKey) || '';
  } catch {
    return '';
  }
}

function clearInviteToken() {
  try { window.sessionStorage.removeItem(albumInviteTokenStorageKey); } catch {}
}

const albumInviteToken = readInviteToken();

function inviteReturnTo() {
  return 'invito-album.html';
}

function normalizeEmail(value) {
  return String(value || '').trim().toLowerCase();
}

function setMessage(text, isError = false) {
  albumInviteMessage.textContent = text;
  albumInviteMessage.classList.toggle('is-error', isError);
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

async function switchAccount() {
  albumInviteSwitchAccount.disabled = true;
  await albumInviteClient.auth.signOut();
  window.location.replace(document.getElementById('album-invite-login').href);
}

async function loadInvite() {
  if (!validToken(albumInviteToken)) {
    setMessage('Il collegamento dell’invito non è valido.', true);
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
    return;
  }

  inviteRecipientEmail = normalizeEmail(data.recipient_email);
  const { data: userData, error: userError } = await albumInviteClient.auth.getUser();
  const authenticatedEmail = normalizeEmail(userData?.user?.email);
  if (userError || !authenticatedEmail || authenticatedEmail !== inviteRecipientEmail) {
    showWrongAccountMessage();
    return;
  }

  albumInviteRecipient.textContent = `Invito inviato a: ${inviteRecipientEmail}`;
  albumInviteResponse.hidden = false;
  setResponseBusy(false);
  setMessage('');
}

async function respondToInvite(rpcName, successMessage) {
  if (!albumInviteEnabled || responsePending || !validToken(albumInviteToken)) return;
  setResponseBusy(true);
  setMessage('Registrazione della risposta...');
  const { error } = await albumInviteClient.rpc(rpcName, { p_token: albumInviteToken });
  if (error) {
    setResponseBusy(false);
    setMessage(unavailableMessage(error), true);
    return;
  }
  albumInviteResponse.hidden = true;
  clearInviteToken();
  if (rpcName === 'accept_my_memory_share_invitation') albumInviteComplete.hidden = false;
  setMessage(successMessage);
}

albumInviteAccept.addEventListener('click', () => void respondToInvite('accept_my_memory_share_invitation', 'Invito accettato.'));
albumInviteDecline.addEventListener('click', () => void respondToInvite('decline_my_memory_share_invitation', 'Invito rifiutato.'));
albumInviteSwitchAccount.addEventListener('click', () => void switchAccount());
void loadInvite();