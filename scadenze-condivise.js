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

async function renderSharedDeadlineImage(target, deadlineId, alt) {
  try {
    const { data, error } = await supabaseClient.functions.invoke('get-shared-deadline-image', {
      body: { deadline_id: deadlineId }
    });
    if (error || typeof data?.signed_url !== 'string') return;
    const signedUrl = new URL(data.signed_url);
    if (signedUrl.origin !== new URL(SUPABASE_URL).origin || !target.isConnected) return;
    const image = document.createElement('img');
    image.alt = alt;
    image.style.objectFit = 'cover';
    image.onload = () => { if (target.isConnected) target.replaceChildren(image); };
    image.onerror = () => { /* Preserve the initial fallback. */ };
    image.src = signedUrl.toString();
  } catch {
    // The initial remains visible when the authorized image is unavailable.
  }
}

function sharedDeadlineRow(deadline) {
  const item = document.createElement('a');
  item.className = 'fa-v2-deadline-card fa-v2-deadline-card--interactive fa-v2-card-media-layout';
  item.href = `scadenza-condivisa.html?deadline_id=${encodeURIComponent(deadline.deadline_id)}`;
  const visual = document.createElement('span');
  visual.className = 'fa-v2-card-visual';
  const thumbnailName = plainText(deadline.shared_item_name) || deadlineType(deadline);
  visual.setAttribute('aria-label', `Miniatura di ${thumbnailName}`);
  visual.textContent = thumbnailName.charAt(0).toLocaleUpperCase('it-IT');
  if (deadline.deadline_id) void renderSharedDeadlineImage(visual, deadline.deadline_id, `Foto di ${thumbnailName}`);
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
  const insurance = document.createElement('p');
  insurance.className = 'fa-v2-card-description';
  insurance.textContent = `Compagnia assicurativa: ${plainText(deadline.insurance_company) || 'Non inserita'}`;
  const owner = document.createElement('p');
  owner.className = 'fa-v2-card-description';
  owner.textContent = deadline.owner_display_name ? `Condivisa da ${deadline.owner_display_name}` : 'Scadenza condivisa';
  copy.append(title);
  if (plateLine) copy.append(plateLine);
  copy.append(metadata, insurance, owner);
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
