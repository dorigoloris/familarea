const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const params = new URLSearchParams(location.search);
const areaId = params.get('area_id');
const returnTo = params.get('return_to');
const pageMessage = document.getElementById('page-message');
const inviteForm = document.getElementById('invite-form');
const inviteFormMessage = document.getElementById('invite-form-message');
const inviteFormSection = document.getElementById('invite-form-section');
const invitesSection = document.getElementById('invites-section');
const invitesList = document.getElementById('invites-list');
const invitesEmpty = document.getElementById('invites-empty');
let manageable = false;
let currentUserEmail = '';

function normalizeEmail(email) {
  return (email || '').trim().toLocaleLowerCase('it-IT');
}

function safeReturnUrl(value) {
  if (!value) return null;
  try {
    const url = new URL(value, location.origin);
    if (url.origin !== location.origin || url.searchParams.get('area_id') !== areaId) return null;
    return `${url.pathname.split('/').pop()}${url.search}${url.hash}`;
  } catch {
    return null;
  }
}

function inviteErrorMessage(error) {
  const technicalMessage = `${error?.message || ''} ${error?.details || ''}`.toLocaleLowerCase('it-IT');
  if (technicalMessage.includes('email non valida')) return 'Inserisci un indirizzo email valido.';
  if (technicalMessage.includes('invito in attesa') || technicalMessage.includes('duplicate key')) return 'Esiste già un invito in attesa per questa email.';
  if (technicalMessage.includes('impossibile creare l') || technicalMessage.includes('già partecipante')) return 'Questa persona è già membro dell’Area.';
  if (technicalMessage.includes('permission denied') || technicalMessage.includes('non autorizzato')) return 'Non sei autorizzato a gestire gli inviti di questa Area.';
  if (technicalMessage.includes('area non trovata')) return 'L’Area non è più disponibile.';
  return 'Non è stato possibile creare l’invito. Riprova.';
}

function logInviteError(operation, error) {
  console.error(`[Inviti Area] ${operation} non riuscita`, {
    code: error?.code || null,
    message: error?.message || 'Errore senza messaggio'
  });
}

function createInviteCard(invite) {
  const card = document.createElement('article');
  card.className = 'invite-card';
  const email = document.createElement('strong');
  email.textContent = invite.invitee_email;
  const revoke = document.createElement('button');
  revoke.type = 'button';
  revoke.textContent = 'Revoca';
  revoke.addEventListener('click', async () => {
    revoke.disabled = true;
    const { error } = await supabaseClient.rpc('revoke_area_invite', { p_invite_id: invite.id });
    if (error) {
      logInviteError('Revoca invito', error);
      pageMessage.textContent = inviteErrorMessage(error);
      revoke.disabled = false;
      return;
    }
    await loadInvites();
  });
  card.append(email, revoke);
  return card;
}

async function loadInvites() {
  const { data, error } = await supabaseClient.rpc('get_area_invites', { p_area_id: areaId });
  if (error) {
    logInviteError('Caricamento inviti', error);
    pageMessage.textContent = inviteErrorMessage(error);
    return false;
  }
  const pending = (data || []).filter((invite) => invite.status === 'pending');
  invitesList.replaceChildren(...pending.map(createInviteCard));
  invitesSection.hidden = false;
  invitesEmpty.hidden = pending.length > 0;
  return true;
}

async function load() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    location.href = 'login.html';
    return;
  }
  if (!areaId) {
    pageMessage.textContent = 'Area non specificata.';
    return;
  }
  currentUserEmail = normalizeEmail(sessionData.session.user.email);
  document.getElementById('back-to-area-link').href = safeReturnUrl(returnTo) || `area.html?area_id=${encodeURIComponent(areaId)}`;
  const [{ data: area, error: areaError }, { data: areas, error: areasError }] = await Promise.all([
    supabaseClient.rpc('get_area', { p_area_id: areaId }),
    supabaseClient.rpc('get_my_areas')
  ]);
  if (areaError || areasError || !area) {
    logInviteError('Caricamento Area', areaError || areasError);
    pageMessage.textContent = 'Area non disponibile.';
    return;
  }
  document.getElementById('area-description').textContent = `Gestisci gli inviti per ${area.name}.`;
  manageable = ['owner', 'admin'].includes((areas || []).find((item) => item.id === areaId)?.role);
  inviteFormSection.hidden = !manageable;
  if (!manageable) {
    pageMessage.textContent = 'Non sei autorizzato a gestire gli inviti di questa Area.';
    return;
  }
  if (await loadInvites()) pageMessage.textContent = '';
}

inviteForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!manageable) return;
  const email = normalizeEmail(document.getElementById('invite-email').value);
  inviteFormMessage.textContent = '';
  if (!email) {
    inviteFormMessage.textContent = 'Inserisci l’email del destinatario.';
    return;
  }
  if (email === currentUserEmail) {
    inviteFormMessage.textContent = 'Non puoi invitare il tuo stesso indirizzo email.';
    return;
  }
  const { error } = await supabaseClient.rpc('create_area_invite', {
    p_area_id: areaId,
    p_invitee_email: email,
    p_expires_at: null
  });
  if (error) {
    logInviteError('Creazione invito', error);
    inviteFormMessage.textContent = inviteErrorMessage(error);
    return;
  }
  inviteForm.reset();
  await loadInvites();
});

load();
