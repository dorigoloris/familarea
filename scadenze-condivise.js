const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const message = document.getElementById('shared-deadlines-message');
const list = document.getElementById('shared-deadlines-list');
const empty = document.getElementById('shared-deadlines-empty');

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
  return new Intl.DateTimeFormat('it-IT', { dateStyle: 'medium' }).format(date);
}

function sharedDeadlineRow(deadline) {
  const item = document.createElement('a');
  item.className = 'fa-v2-list-row fa-v2-list-row--media';
  item.href = `scadenza-condivisa.html?deadline_id=${encodeURIComponent(deadline.deadline_id)}`;
  const visual = document.createElement('span');
  visual.setAttribute('aria-hidden', 'true');
  visual.textContent = (deadline.title || 'S').trim().charAt(0).toLocaleUpperCase('it-IT');
  const copy = document.createElement('div');
  copy.className = 'fa-v2-card-content';
  const title = document.createElement('h3');
  title.className = 'fa-v2-card-title';
  title.textContent = deadline.title || 'Scadenza FamilArea';
  const owner = document.createElement('p');
  owner.className = 'fa-v2-card-description';
  owner.textContent = deadline.owner_display_name ? `Condivisa da ${deadline.owner_display_name}` : 'Scadenza condivisa';
  const metadata = document.createElement('p');
  metadata.className = 'fa-v2-card-description';
  metadata.textContent = `${categoryLabel(deadline.category)} · ${dateLabel(deadline.first_due_on)}`;
  copy.append(title, owner, metadata);
  item.append(visual, copy);
  return item;
}

async function load() {
  if (window.FamilAreaRequirePersonal && !await window.FamilAreaRequirePersonal()) return;
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }

  const { data, error } = await supabaseClient.rpc('get_my_shared_deadlines');
  if (error) {
    console.error('get_my_shared_deadlines failed', error);
    message.textContent = 'Impossibile caricare le Scadenze condivise.';
    return;
  }

  const deadlines = data || [];
  list.replaceChildren(...deadlines.map(sharedDeadlineRow));
  empty.hidden = deadlines.length > 0;
  message.textContent = '';
}

load();
