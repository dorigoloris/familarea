const supabaseClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const statusLabels = { active: 'Attivo', cancelled: 'Annullato' };

function eventIdOf(event) {
  return event.id || event.event_id;
}

function when(event) {
  if (!event.starts_at) return 'Data non indicata';
  const start = new Date(event.starts_at);
  const date = start.toLocaleDateString('it-IT');
  if (event.is_all_day) return `${date} · Tutto il giorno`;
  const time = start.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' });
  const end = event.ends_at
    ? ` – ${new Date(event.ends_at).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })}`
    : '';
  return `${date}, ${time}${end}`;
}

function createEventRow(event) {
  const row = document.createElement('a');
  row.className = 'fa-v2-list-row fa-v2-content-action-row';
  row.href = `evento.html?event_id=${encodeURIComponent(eventIdOf(event))}`;
  row.setAttribute('aria-label', `Apri evento ${event.title}`);

  const main = document.createElement('div');
  main.className = 'fa-v2-card-content';
  const title = document.createElement('h3');
  title.className = 'fa-v2-card-title';
  title.textContent = event.title;
  const context = document.createElement('p');
  context.className = 'fa-v2-card-description';
  context.textContent = 'Evento';
  main.append(title, context);

  const details = document.createElement('div');
  details.className = 'fa-v2-card-content';
  const date = document.createElement('p');
  date.className = 'fa-v2-card-description';
  date.textContent = `${when(event)}${event.location ? ` · ${event.location}` : ''}`;
  details.appendChild(date);
  if (event.status && event.status !== 'active') {
    const status = document.createElement('span');
    status.className = 'fa-v2-badge';
    status.textContent = statusLabels[event.status] || event.status;
    details.appendChild(status);
  }

  row.append(main, details);
  return row;
}

async function load() {
  const { data: session } = await supabaseClient.auth.getSession();
  if (!session.session) {
    location.href = 'login.html';
    return;
  }

  const message = document.getElementById('global-message');
  const list = document.getElementById('global-events-list');
  const { data, error } = await supabaseClient.rpc('get_visible_events');
  if (error) {
    message.textContent = 'Impossibile caricare gli eventi visibili.';
    return;
  }

  const events = data || [];
  const section = document.getElementById('global-events-section');
  const empty = document.getElementById('events-empty');
  section.hidden = false;
  empty.hidden = events.length > 0;
  list.replaceChildren(...events.map(createEventRow));
  message.textContent = '';
}

load();
