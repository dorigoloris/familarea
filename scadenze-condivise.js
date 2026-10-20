const supabaseClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

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

function sharedDeadlineRow(deadline) {
  const item = document.createElement('a');
  item.className = 'fa-v2-list-row fa-v2-list-row--media';
  item.href = `scadenza-condivisa.html?deadline_id=${encodeURIComponent(deadline.deadline_id)}`;
  const visual = document.createElement('span');
  visual.setAttribute('aria-hidden', 'true');
  visual.textContent = sharedDeadlineTitle(deadline).charAt(0).toLocaleUpperCase('it-IT');
  const copy = document.createElement('div');
  copy.className = 'fa-v2-card-content';
  const title = document.createElement('h3');
  title.className = 'fa-v2-card-title';
  title.textContent = sharedDeadlineTitle(deadline);
  const plate = deadline.shared_item_category === 'vehicle' ? plainText(deadline.shared_vehicle_plate) : '';
  const plateLine = plate ? document.createElement('p') : null;
  if (plateLine) {
    plateLine.className = 'fa-v2-card-description';
    plateLine.textContent = `Targa: ${plate}`;
  }
  const metadata = document.createElement('p');
  metadata.className = 'fa-v2-card-description';
  metadata.textContent = `Scadenza: ${dateLabel(deadline.first_due_on)}`;
  const owner = document.createElement('p');
  owner.className = 'fa-v2-card-description';
  owner.textContent = deadline.owner_display_name ? `Condivisa da ${deadline.owner_display_name}` : 'Scadenza condivisa';
  copy.append(title);
  if (plateLine) copy.append(plateLine);
  copy.append(metadata, owner);
  item.append(visual, copy);
  return item;
}

async function load() {
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
