const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const pageMessage = document.getElementById('page-message');
const invitesSection = document.getElementById('invites-section');
const invitesList = document.getElementById('invites-list');
const invitesEmpty = document.getElementById('invites-empty');

function fullName(firstName, lastName, fallback = '') { return `${firstName || ''} ${lastName || ''}`.trim() || fallback; }
function statusLabel(status) { return ({ pending: 'In attesa', accepted: 'Accettato', declined: 'Rifiutato', revoked: 'Revocato', expired: 'Scaduto' })[status] || status; }

function inviteErrorMessage(error) {
  const text = `${error?.message || ''} ${error?.details || ''}`.toLowerCase();
  if (text.includes('email dell') && text.includes('non verificata')) return 'Per gestire gli inviti devi prima verificare l’email del tuo account.';
  if (text.includes('gia') && text.includes('partecipante')) return 'Sei già partecipante di questa Area.';
  if (text.includes('conflitto')) return 'Non è possibile completare la risposta a questo invito.';
  if (text.includes('scaduto')) return 'Questo invito è scaduto.';
  if (text.includes('non e') && text.includes('accettabile')) return 'Questo invito è stato revocato, rifiutato o non è più valido.';
  if (text.includes('permission denied') || text.includes('non autorizzato')) return 'Non sei autorizzato a gestire questo invito.';
  return 'Non è stato possibile completare l’operazione. Riprova.';
}

function setCardBusy(card, busy) { card.querySelectorAll('button').forEach((button) => { button.disabled = busy; }); }

async function respondToInvite(invite, rpcName, card) {
  setCardBusy(card, true);
  pageMessage.textContent = rpcName === 'accept_area_invite' ? 'Accettazione invito in corso…' : 'Rifiuto invito in corso…';
  const { error } = await supabaseClient.rpc(rpcName, { p_invite_id: invite.invite_id });
  if (error) { setCardBusy(card, false); pageMessage.textContent = inviteErrorMessage(error); return; }
  pageMessage.textContent = rpcName === 'accept_area_invite' ? 'Invito accettato. Ora fai parte dell’Area.' : 'Invito rifiutato.';
  await loadInvites();
}

function createInviteCard(invite) {
  const article = document.createElement('article');
  article.className = 'invite-card fa-list-row';
  const details = document.createElement('div');
  const title = document.createElement('h3');
  const inviter = document.createElement('p');
  const metadata = document.createElement('p');
  const status = document.createElement('span');
  title.textContent = invite.area_name || 'Area FamilArea';
  const inviterName = fullName(invite.inviter_first_name, invite.inviter_last_name);
  inviter.textContent = inviterName ? `Invitato da ${inviterName}` : 'Mittente non indicato';
  status.className = `invite-status fa-status-badge invite-status-${invite.status}`;
  status.textContent = statusLabel(invite.status);
  metadata.textContent = 'Invito a partecipare all’Area';
  details.append(title, inviter, status, metadata);
  article.appendChild(details);
  if (invite.status === 'pending') {
    const actions = document.createElement('div');
    actions.className = 'invite-actions';
    const decline = document.createElement('button');
    decline.type = 'button'; decline.className = 'secondary-button'; decline.textContent = 'Rifiuta';
    decline.addEventListener('click', () => respondToInvite(invite, 'decline_area_invite', article));
    const accept = document.createElement('button');
    accept.type = 'button'; accept.textContent = 'Accetta';
    accept.addEventListener('click', () => respondToInvite(invite, 'accept_area_invite', article));
    actions.append(decline, accept); article.appendChild(actions);
  }
  return article;
}

async function loadInvites() {
  const { data, error } = await supabaseClient.rpc('get_my_area_invites');
  if (error) { pageMessage.textContent = inviteErrorMessage(error); return; }
  invitesSection.hidden = false;
  invitesList.replaceChildren();
  invitesEmpty.hidden = Boolean(data?.length);
  (data || []).forEach((invite) => invitesList.appendChild(createInviteCard(invite)));
}

async function loadPage() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  await loadInvites();
  if (invitesSection.hidden === false) pageMessage.textContent = '';
}

loadPage();
