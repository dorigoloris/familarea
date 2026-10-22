const connectionClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const tokenKey = 'familarea:contact-connection-invite-token';
const message = document.getElementById('connection-message');
const auth = document.getElementById('connection-auth');
const response = document.getElementById('connection-response');
const complete = document.getElementById('connection-complete');
const sender = document.getElementById('connection-sender');
const accept = document.getElementById('connection-accept');
const decline = document.getElementById('connection-decline');

const validToken = (value) => /^[A-Za-z0-9_-]{32,128}$/.test(value || '');

function token() {
  const url = new URL(location.href);
  const query = url.searchParams.get('token') || '';
  const fragment = new URLSearchParams(url.hash.slice(1)).get('token') || '';
  const value = fragment || query;
  if (validToken(value)) {
    sessionStorage.setItem(tokenKey, value);
    url.searchParams.delete('token');
    url.hash = '';
    history.replaceState(history.state, '', url.pathname + url.search);
    return value;
  }
  return sessionStorage.getItem(tokenKey) || '';
}

const inviteToken = token();
const returnTo = 'invito-collegamento.html';

function set(text, error = false) {
  message.textContent = text;
  message.classList.toggle('is-error', error);
}

function unavailable() {
  return "Questo invito non \u00e8 disponibile, \u00e8 scaduto o non corrisponde all'email verificata dell'account.";
}

function showComplete() {
  response.hidden = true;
  complete.hidden = false;
  set('Collegamento completato. Ora siete presenti nelle rispettive rubriche.');
}

async function load() {
  if (!validToken(inviteToken)) {
    set("Il collegamento dell'invito non \u00e8 valido.", true);
    return;
  }

  document.getElementById('connection-login').href = FamilAreaAuthUtils.loginUrl(returnTo);
  document.getElementById('connection-register').href = `registrati.html?return_to=${encodeURIComponent(FamilAreaAuthUtils.safeReturnTo(returnTo))}`;

  const { data: { session } } = await connectionClient.auth.getSession();
  if (!session) {
    set('');
    auth.hidden = false;
    return;
  }

  const { data, error } = await connectionClient.rpc('get_contact_connection_invite', { p_token: inviteToken });
  if (error || !data) {
    set(unavailable(), true);
    return;
  }

  sender.textContent = `${data.sender_name || 'Un utente FamilArea'} ti invita a collegare i contatti.`;
  response.hidden = false;
  set('');
}

async function answer(yes) {
  accept.disabled = true;
  decline.disabled = true;
  set('Registrazione della risposta...');

  const { data, error } = await connectionClient.rpc('respond_contact_connection_invite', {
    p_token: inviteToken,
    p_accept: yes
  });
  if (error) {
    accept.disabled = false;
    decline.disabled = false;
    set(unavailable(), true);
    return;
  }

  sessionStorage.removeItem(tokenKey);
  if (yes || data?.status === 'accepted') {
    showComplete();
    return;
  }

  response.hidden = true;
  set('Invito rifiutato.');
}

accept.addEventListener('click', () => void answer(true));
decline.addEventListener('click', () => void answer(false));
void load();
