const supabaseClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const deadlineId = new URLSearchParams(location.search).get('deadline_id');

const message = document.getElementById('shared-deadline-message');
const view = document.getElementById('shared-deadline-view');
const relinquishButton = document.getElementById('shared-deadline-relinquish');
let collaborationId = null;

function categoryLabel(category) {
  return ({
    vehicle: 'Veicoli',
    home: 'Casa',
    personal_document: 'Documenti personali',
    document: 'Documenti personali',
    other: 'Altro'
  })[category] || category || 'Scadenza';
}

function dateLabel(value) {
  const date = value ? new Date(`${value}T00:00:00`) : null;
  if (!date || Number.isNaN(date.getTime())) return 'Data da definire';
  return new Intl.DateTimeFormat('it-IT', { dateStyle: 'long' }).format(date);
}

function statusLabel(status) {
  return ({ active: 'Attiva', completed: 'Completata', expired: 'Scaduta', cancelled: 'Annullata' })[status] || status || 'Non disponibile';
}

function render(deadline) {
  collaborationId = deadline.collaboration_id || null;
  document.getElementById('shared-deadline-title').textContent = deadline.title || 'Scadenza FamilArea';
  document.getElementById('shared-deadline-owner').textContent = deadline.owner_display_name ? `Condivisa da ${deadline.owner_display_name}` : 'Scadenza condivisa';
  document.getElementById('shared-deadline-category').textContent = categoryLabel(deadline.category);
  document.getElementById('shared-deadline-date').textContent = dateLabel(deadline.first_due_on);
  document.getElementById('shared-deadline-status').textContent = statusLabel(deadline.status);
  view.hidden = false;
  message.textContent = '';
}

async function relinquishSharedDeadline() {
  if (!collaborationId || !await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Rinunciare alla condivisione?',
    message: 'Non potrai più visualizzare questa Scadenza né trovarla nel Calendario.',
    confirmText: 'Rinuncia'
  })) return;

  relinquishButton.disabled = true;
  message.textContent = 'Rinuncia in corso...';
  const { error } = await supabaseClient.rpc('revoke_deadline_collaboration', {
    p_collaboration_id: collaborationId
  });
  if (error) {
    relinquishButton.disabled = false;
    message.textContent = 'Non è stato possibile rinunciare alla condivisione. Riprova.';
    return;
  }
  window.location.href = 'scadenze-condivise.html';
}

relinquishButton.addEventListener('click', () => { void relinquishSharedDeadline(); });

async function load() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  if (!deadlineId) {
    message.textContent = 'Scadenza condivisa non specificata.';
    return;
  }

  const { data, error } = await supabaseClient.rpc('get_shared_deadline', { p_deadline_id: deadlineId });
  if (error || !data) {
    console.error('get_shared_deadline failed', error);
    message.textContent = 'Questa Scadenza condivisa non è più disponibile.';
    return;
  }
  render(data);
}

load();
