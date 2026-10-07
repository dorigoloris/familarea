const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const deadlineId = new URLSearchParams(location.search).get('deadline_id');

const message = document.getElementById('shared-deadline-message');
const view = document.getElementById('shared-deadline-view');

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
  document.getElementById('shared-deadline-title').textContent = deadline.title || 'Scadenza FamilArea';
  document.getElementById('shared-deadline-owner').textContent = deadline.owner_display_name ? `Condivisa da ${deadline.owner_display_name}` : 'Scadenza condivisa';
  document.getElementById('shared-deadline-category').textContent = categoryLabel(deadline.category);
  document.getElementById('shared-deadline-date').textContent = dateLabel(deadline.first_due_on);
  document.getElementById('shared-deadline-status').textContent = statusLabel(deadline.status);
  view.hidden = false;
  message.textContent = '';
}

async function load() {
  if (window.FamilAreaRequirePersonal && !await window.FamilAreaRequirePersonal()) return;
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
