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

function plainText(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function deadlineType(deadline) {
  return plainText(deadline.title) || 'Scadenza FamilArea';
}

function sharedDeadlineTitle(deadline) {
  const itemName = plainText(deadline.shared_item_name);
  const type = deadlineType(deadline);
  return itemName ? `${itemName} · ${type}` : type;
}

function itemLabel(category) {
  if (category === 'vehicle') return 'Veicolo';
  if (category === 'home') return 'Immobile';
  return 'Elemento associato';
}

function statusLabel(status) {
  return ({ active: 'Attiva', completed: 'Completata', expired: 'Scaduta', cancelled: 'Annullata' })[status] || status || 'Non disponibile';
}

function render(deadline) {
  collaborationId = deadline.collaboration_id || null;
  const itemName = plainText(deadline.shared_item_name);
  const isVehicle = deadline.shared_item_category === 'vehicle';
  const vehiclePlate = isVehicle ? plainText(deadline.shared_vehicle_plate) : '';
  const itemRow = document.getElementById('shared-deadline-item-row');
  const plateRow = document.getElementById('shared-deadline-plate-row');

  document.getElementById('shared-deadline-title').textContent = sharedDeadlineTitle(deadline);
  document.getElementById('shared-deadline-owner').textContent = deadline.owner_display_name ? `Condivisa da ${deadline.owner_display_name}` : 'Scadenza condivisa';
  document.getElementById('shared-deadline-item-label').textContent = itemLabel(deadline.shared_item_category);
  document.getElementById('shared-deadline-item').textContent = itemName;
  itemRow.hidden = !itemName;
  document.getElementById('shared-deadline-plate').textContent = vehiclePlate;
  plateRow.hidden = !vehiclePlate;
  document.getElementById('shared-deadline-type').textContent = deadlineType(deadline);
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
