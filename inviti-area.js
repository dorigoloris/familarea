const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const pageMessage = document.getElementById('page-message');
const areaDescription = document.getElementById('area-description');
const backToAreaLink = document.getElementById('back-to-area-link');
const inviteFormSection = document.getElementById('invite-form-section');
const inviteForm = document.getElementById('invite-form');
const inviteEmail = document.getElementById('invite-email');
const inviteFirstName = document.getElementById('invite-first-name');
const inviteLastName = document.getElementById('invite-last-name');
const sendInviteButton = document.getElementById('send-invite-button');
const resetInviteButton = document.getElementById('reset-invite-button');
const inviteFormMessage = document.getElementById('invite-form-message');
const invitesSection = document.getElementById('invites-section');
const invitesList = document.getElementById('invites-list');
const invitesEmpty = document.getElementById('invites-empty');

let currentAreaId = null;
let isAreaAdmin = false;

function fullName(firstName, lastName, fallback = '') {
  return `${firstName || ''} ${lastName || ''}`.trim() || fallback;
}

function inviteStatusLabel(status) {
  return ({ pending: 'In attesa', accepted: 'Accettato', declined: 'Rifiutato', revoked: 'Revocato', expired: 'Scaduto' })[status] || status;
}

function inviteErrorMessage(error) {
  const text = `${error?.message || ''} ${error?.details || ''}`.toLowerCase();
  if (text.includes('impossibile creare l') || text.includes('gia') && text.includes('partecipante')) return 'Questo destinatario è già partecipante dell’Area oppure non può essere invitato.';
  if (text.includes('email dell') && text.includes('non verificata')) return 'Il destinatario dovrà verificare la propria email prima di poter accettare l’invito.';
  if (text.includes('invito in attesa')) return 'Esiste già un invito in attesa per questo indirizzo.';
  if (text.includes('permission denied') || text.includes('non autorizzato')) return 'Non sei autorizzato a gestire gli inviti di questa Area.';
  if (text.includes('non accettabile') || text.includes('gia concluso')) return 'Questo invito non può più essere modificato.';
  return 'Non è stato possibile completare l’operazione. Riprova.';
}

function resetInviteForm() {
  inviteForm.reset();
  inviteFormMessage.textContent = '';
}

function createInviteCard(invite) {
  const article = document.createElement('article');
  article.className = 'invite-card';
  const details = document.createElement('div');
  const email = document.createElement('h3');
  const name = document.createElement('p');
  const metadata = document.createElement('p');
  const status = document.createElement('span');

  email.textContent = invite.recipient_email;
  const recipientName = fullName(invite.first_name, invite.last_name);
  name.textContent = recipientName || 'Nome non indicato';
  status.className = `invite-status invite-status-${invite.status}`;
  status.textContent = inviteStatusLabel(invite.status);
  metadata.textContent = 'Invito partecipante';
  details.append(email, name, status, metadata);
  article.appendChild(details);

  if (invite.status === 'pending') {
    const revoke = document.createElement('button');
    revoke.type = 'button';
    revoke.className = 'secondary-button invite-revoke-button';
    revoke.textContent = 'Revoca';
    revoke.addEventListener('click', async () => {
      revoke.disabled = true;
      revoke.textContent = 'Revoca in corso…';
      pageMessage.textContent = '';
      const { error } = await supabaseClient.rpc('revoke_area_invite', {
        p_area_id: currentAreaId,
        p_invite_id: invite.invite_id
      });
      if (error) {
        revoke.disabled = false;
        revoke.textContent = 'Revoca';
        pageMessage.textContent = inviteErrorMessage(error);
        return;
      }
      pageMessage.textContent = 'Invito revocato.';
      await loadInvites();
    });
    article.appendChild(revoke);
  }
  return article;
}

async function loadInvites() {
  const { data, error } = await supabaseClient.rpc('get_area_invites', { p_area_id: currentAreaId });
  if (error) {
    pageMessage.textContent = inviteErrorMessage(error);
    return false;
  }
  isAreaAdmin = true;
  inviteFormSection.hidden = false;
  invitesSection.hidden = false;
  invitesList.replaceChildren();
  invitesEmpty.hidden = Boolean(data?.length);
  (data || []).forEach((invite) => invitesList.appendChild(createInviteCard(invite)));
  return true;
}

async function loadPage() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }
  currentAreaId = new URLSearchParams(window.location.search).get('area_id');
  if (!currentAreaId) {
    pageMessage.textContent = 'Area non specificata.';
    return;
  }
  backToAreaLink.href = `area.html?area_id=${encodeURIComponent(currentAreaId)}`;
  const { data: area } = await supabaseClient.from('areas').select('name').eq('id', currentAreaId).single();
  if (area?.name) areaDescription.textContent = `Gestisci gli inviti per ${area.name}.`;

  const canLoadInvites = await loadInvites();
  if (!canLoadInvites) return;
  pageMessage.textContent = '';
}

inviteForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!isAreaAdmin) return;
  const email = inviteEmail.value.trim();
  if (!email) {
    inviteFormMessage.textContent = 'Inserisci l’email del destinatario.';
    return;
  }
  sendInviteButton.disabled = true;
  sendInviteButton.textContent = 'Creazione in corso…';
  inviteFormMessage.textContent = '';
  const { error } = await supabaseClient.rpc('create_area_invite', {
    p_area_id: currentAreaId,
    p_email: email,
    p_first_name: inviteFirstName.value.trim() || null,
    p_last_name: inviteLastName.value.trim() || null,
    p_target_managed_profile_id: null
  });
  sendInviteButton.disabled = false;
  sendInviteButton.textContent = 'Crea invito';
  if (error) {
    inviteFormMessage.textContent = inviteErrorMessage(error);
    return;
  }
  resetInviteForm();
  pageMessage.textContent = 'Invito creato correttamente.';
  await loadInvites();
});

resetInviteButton.addEventListener('click', resetInviteForm);
loadPage();
