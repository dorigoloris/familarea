const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const pageMessage = document.getElementById('page-message');
const invitesSection = document.getElementById('invites-section');
const invitesList = document.getElementById('invites-list');
const invitesEmpty = document.getElementById('invites-empty');
let pageMessageTimeout;

function setPageMessage(text = '', timeout = 0) {
  window.clearTimeout(pageMessageTimeout);
  pageMessage.textContent = text;
  if (text && timeout) pageMessageTimeout = window.setTimeout(() => { pageMessage.textContent = ''; }, timeout);
}

function acceptedInviteMessage(kind) {
  return ({ area: 'Invito Area accettato.', family: 'Invito Famiglia accettato.', event: 'Invito Evento accettato.', suggestion: 'Suggerimento contatto accettato.' })[kind] || 'Invito accettato.';
}

function fullName(firstName, lastName, fallback = '') { return `${firstName || ''} ${lastName || ''}`.trim() || fallback; }
function statusLabel(status) { return ({ pending: 'In attesa', accepted: 'Attivo', declined: 'Rifiutato', revoked: 'Revocato', expired: 'Scaduto' })[status] || status; }
function inviteSenderLabel(invite) {
  const organizationName = (invite.organization_name || '').trim();
  if (organizationName) return `Invitato da ${organizationName}`;
  const inviterName = fullName(invite.inviter_first_name, invite.inviter_last_name);
  return inviterName ? `Invitato da ${inviterName}` : '';
}

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

function eventDateLabel(invite) {
  const startsAt = new Date(invite.starts_at);
  if (Number.isNaN(startsAt.getTime())) return 'Data da definire';
  const dateFormat = new Intl.DateTimeFormat('it-IT', { dateStyle: 'medium' });
  if (invite.is_all_day) return dateFormat.format(startsAt);
  const dateTimeFormat = new Intl.DateTimeFormat('it-IT', { dateStyle: 'medium', timeStyle: 'short' });
  const startLabel = dateTimeFormat.format(startsAt);
  const endsAt = invite.ends_at ? new Date(invite.ends_at) : null;
  if (!endsAt || Number.isNaN(endsAt.getTime())) return startLabel;
  return `${startLabel} – ${new Intl.DateTimeFormat('it-IT', { timeStyle: 'short' }).format(endsAt)}`;
}

function setCardBusy(card, busy) { card.querySelectorAll('button').forEach((button) => { button.disabled = busy; }); }

async function respondToInvite(invite, rpcName, card, kind = 'area') {
  setCardBusy(card, true);
  setPageMessage(rpcName.startsWith('accept_') ? 'Accettazione invito in corso…' : 'Rifiuto invito in corso…');
  const params = kind === 'suggestion'
    ? { p_suggestion_id: invite.suggestion_id }
    : { p_invite_id: invite.invite_id };
  const { error } = await supabaseClient.rpc(rpcName, params);
  if (error) { setCardBusy(card, false); setPageMessage(inviteErrorMessage(error)); return; }
  if (await loadInvites()) {
    if (rpcName.startsWith('accept_')) setPageMessage(acceptedInviteMessage(kind), 3000);
    else setPageMessage('');
  }
  window.dispatchEvent(new CustomEvent('familarea:invites-changed'));
}

function createInviteCard(invite) {
  const article = document.createElement('article');
  article.className = 'invite-card fa-list-row';
  const senderLabel = inviteSenderLabel(invite);
  if (invite.status === 'accepted') {
    article.classList.add('invite-card-active');
    const details = document.createElement('div');
    details.className = 'invite-active-details';
    const title = document.createElement('h3');
    title.textContent = invite.area_name || 'Area FamilArea';
    const status = document.createElement('span');
    status.className = 'invite-status fa-status-badge invite-status-accepted';
    status.textContent = 'Attivo';
    details.append(title);
    if (senderLabel) {
      const inviter = document.createElement('p');
      inviter.textContent = senderLabel;
      details.append(inviter);
    }
    article.append(details, status);
    return article;
  }
  const details = document.createElement('div');
  const title = document.createElement('h3');
  const inviter = document.createElement('p');
  const metadata = document.createElement('p');
  const status = document.createElement('span');
  title.textContent = invite.area_name || 'Area FamilArea';
  inviter.textContent = senderLabel;
  status.className = `invite-status fa-status-badge invite-status-${invite.status}`;
  status.textContent = statusLabel(invite.status);
  metadata.textContent = 'Invito a partecipare all’Area';
  details.append(title);
  if (senderLabel) details.append(inviter);
  details.append(status, metadata);
  article.appendChild(details);
  if (invite.status === 'pending') {
    const actions = document.createElement('div');
    actions.className = 'invite-actions';
    const decline = document.createElement('button');
    decline.type = 'button'; decline.className = 'fa-button fa-button-secondary'; decline.textContent = 'Rifiuta';
    decline.addEventListener('click', () => respondToInvite(invite, 'decline_my_area_invite', article));
    const accept = document.createElement('button');
    accept.type = 'button'; accept.textContent = 'Accetta';
    accept.addEventListener('click', () => respondToInvite(invite, 'accept_my_area_invite', article));
    actions.append(decline, accept); article.appendChild(actions);
  }
  return article;
}

function createFamilyInviteCard(invite) {
  const article = document.createElement('article');
  article.className = 'invite-card fa-list-row family-invite-card';
  const details = document.createElement('div');
  const type = document.createElement('p');
  type.className = 'section-kicker'; type.textContent = 'Famiglia';
  const title = document.createElement('h3');
  const inviter = fullName(invite.inviter_first_name, invite.inviter_last_name, 'Un membro FamilArea');
  title.textContent = `${inviter} ti invita a entrare nella ${invite.family_name || 'sua Famiglia'}`;
  const relation = document.createElement('p');
  relation.textContent = `Relazione: ${({ partner: 'Partner', child: 'Figlio/a', parent: 'Genitore', grandparent: 'Nonno/a', sibling: 'Fratello/Sorella', other: 'Altro' })[invite.relationship] || 'Membro della Famiglia'}`;
  const status = document.createElement('span');
  status.className = `invite-status fa-status-badge invite-status-${invite.status}`;
  status.textContent = statusLabel(invite.status);
  details.append(type, title, relation, status);
  article.append(details);
  if (invite.status === 'pending') {
    const actions = document.createElement('div'); actions.className = 'invite-actions';
    const decline = document.createElement('button');
    decline.type = 'button'; decline.className = 'fa-button fa-button-secondary'; decline.textContent = 'Rifiuta';
    decline.addEventListener('click', () => respondToInvite(invite, 'decline_my_family_invite', article, 'family'));
    const accept = document.createElement('button');
    accept.type = 'button'; accept.textContent = 'Accetta';
    accept.addEventListener('click', () => respondToInvite(invite, 'accept_my_family_invite', article, 'family'));
    actions.append(decline, accept); article.append(actions);
  }
  return article;
}

function createEventInviteCard(invite) {
  const article = document.createElement('article');
  article.className = 'invite-card fa-list-row event-invite-card';
  const details = document.createElement('div');
  const type = document.createElement('p');
  type.className = 'section-kicker'; type.textContent = 'Evento';
  const title = document.createElement('h3');
  title.textContent = invite.event_title || 'Evento FamilArea';
  const organizer = document.createElement('p');
  organizer.textContent = `Organizzato da: ${invite.organizer_name || 'Organizzatore FamilArea'}`;
  const date = document.createElement('p');
  date.textContent = `Data e ora: ${eventDateLabel(invite)}`;
  const status = document.createElement('span');
  status.className = `invite-status fa-status-badge invite-status-${invite.status}`;
  status.textContent = statusLabel(invite.status);
  details.append(type, title, organizer, date);
  if (invite.area_name) {
    const area = document.createElement('p');
    area.textContent = `Area: ${invite.area_name}`;
    details.append(area);
  }
  details.append(status);
  article.append(details);
  if (invite.status === 'pending') {
    const actions = document.createElement('div'); actions.className = 'invite-actions';
    const decline = document.createElement('button');
    decline.type = 'button'; decline.className = 'fa-button fa-button-secondary'; decline.textContent = 'Rifiuta';
    decline.addEventListener('click', () => respondToInvite(invite, 'decline_my_event_invite', article, 'event'));
    const accept = document.createElement('button');
    accept.type = 'button'; accept.textContent = 'Accetta';
    accept.addEventListener('click', () => respondToInvite(invite, 'accept_my_event_invite', article, 'event'));
    actions.append(decline, accept); article.append(actions);
  }
  return article;
}

function createContactSuggestionCard(suggestion) {
  const article = document.createElement('article');
  article.className = 'invite-card fa-list-row contact-suggestion-card';
  const details = document.createElement('div');
  const type = document.createElement('p'); type.className = 'section-kicker'; type.textContent = 'Suggerimento contatto';
  const title = document.createElement('h3');
  const suggestedName = fullName(suggestion.suggested_first_name, suggestion.suggested_last_name, 'un contatto');
  title.textContent = `${suggestion.sender_name || 'Un utente FamilArea'} ti suggerisce ${suggestedName} come contatto.`;
  const status = document.createElement('span');
  status.className = 'invite-status fa-status-badge invite-status-pending'; status.textContent = 'In attesa';
  details.append(type, title, status); article.append(details);
  const actions = document.createElement('div'); actions.className = 'invite-actions';
  const decline = document.createElement('button');
  decline.type = 'button'; decline.className = 'fa-button fa-button-secondary'; decline.textContent = 'Ignora';
  decline.addEventListener('click', () => respondToInvite(suggestion, 'decline_my_contact_suggestion', article, 'suggestion'));
  const accept = document.createElement('button');
  accept.type = 'button'; accept.textContent = 'Aggiungi ai Contatti';
  accept.addEventListener('click', () => respondToInvite(suggestion, 'accept_my_contact_suggestion', article, 'suggestion'));
  actions.append(decline, accept); article.append(actions);
  return article;
}

async function loadInvites() {
  const [areaResult, familyResult, eventResult, suggestionResult] = await Promise.all([
    supabaseClient.rpc('get_my_area_invites'),
    supabaseClient.rpc('get_my_family_invites'),
    supabaseClient.rpc('get_my_event_invites'),
    supabaseClient.rpc('get_my_contact_suggestions')
  ]);
  if (areaResult.error) { setPageMessage(inviteErrorMessage(areaResult.error)); return false; }
  if (familyResult.error) console.error('get_my_family_invites failed', familyResult.error);
  if (eventResult.error) console.error('get_my_event_invites failed', eventResult.error);
  if (suggestionResult.error) console.error('get_my_contact_suggestions failed', suggestionResult.error);
  invitesSection.hidden = false;
  invitesList.replaceChildren();
  const visibleAreaInvites = (areaResult.data || [])
    .filter((invite) => invite.status === 'pending' || invite.status === 'accepted')
    .sort((left, right) => (left.status === 'pending' ? 0 : 1) - (right.status === 'pending' ? 0 : 1));
  const visibleFamilyInvites = (familyResult.data || []).filter((invite) => invite.status === 'pending');
  const visibleEventInvites = (eventResult.data || []).filter((invite) => invite.status === 'pending');
  const visibleSuggestions = (suggestionResult.data || []).filter((suggestion) => suggestion.status === 'pending');
  invitesEmpty.hidden = visibleAreaInvites.length + visibleFamilyInvites.length + visibleEventInvites.length + visibleSuggestions.length > 0;
  visibleFamilyInvites.forEach((invite) => invitesList.appendChild(createFamilyInviteCard(invite)));
  visibleEventInvites.forEach((invite) => invitesList.appendChild(createEventInviteCard(invite)));
  visibleSuggestions.forEach((suggestion) => invitesList.appendChild(createContactSuggestionCard(suggestion)));
  visibleAreaInvites.forEach((invite) => invitesList.appendChild(createInviteCard(invite)));
  return true;
}

async function loadPage() {
  if (window.FamilAreaRequirePersonal && !await window.FamilAreaRequirePersonal()) return;
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  await loadInvites();
  if (invitesSection.hidden === false) setPageMessage('');
}

loadPage();
