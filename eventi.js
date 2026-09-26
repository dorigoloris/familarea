const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const statusLabels = {
  active: 'Attivo',
  cancelled: 'Annullato'
};

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

function eventHref(event, areaId = event.area_id) {
  const query = new URLSearchParams({ event_id: eventIdOf(event) });
  if (areaId) query.set('area_id', areaId);
  return `evento.html?${query}`;
}

function createContextualCard(event, areaId) {
  const article = document.createElement('article');
  article.className = 'activity-card event-card';
  const title = document.createElement('h2');
  title.className = 'activity-card-title';
  title.textContent = event.title;

  const metadata = document.createElement('div');
  metadata.className = 'activity-card-meta';
  if (event.status && event.status !== 'active') {
    const status = document.createElement('span');
    status.className = 'activity-status-badge';
    status.textContent = statusLabels[event.status] || event.status;
    metadata.appendChild(status);
  }

  const info = document.createElement('p');
  info.className = 'activity-card-due';
  info.textContent = `${when(event)}${event.location ? ` · ${event.location}` : ''}`;
  const open = document.createElement('a');
  open.className = 'btn activity-open-link';
  open.href = eventHref(event, areaId);
  open.textContent = 'Apri';
  article.append(title, metadata, info, open);
  return article;
}

function createGlobalRow(event) {
  const row = document.createElement('a');
  row.className = 'global-activity-row';
  row.href = eventHref(event);
  row.setAttribute('aria-label', `Apri evento ${event.title}`);

  const main = document.createElement('div');
  main.className = 'global-activity-main';
  const title = document.createElement('h2');
  title.textContent = event.title;
  const context = document.createElement('p');
  context.className = 'global-activity-area';
  context.textContent = event.area_id ? 'Area condivisa' : 'Personale';
  main.append(title, context);

  const details = document.createElement('div');
  details.className = 'global-activity-details';
  const date = document.createElement('span');
  date.className = 'global-activity-date';
  date.textContent = `${when(event)}${event.location ? ` · ${event.location}` : ''}`;
  details.appendChild(date);
  if (event.status && event.status !== 'active') {
    const badges = document.createElement('div');
    badges.className = 'global-activity-badges';
    const status = document.createElement('span');
    status.className = `global-activity-status global-activity-status-${event.status}`;
    status.textContent = statusLabels[event.status] || event.status;
    badges.appendChild(status);
    details.appendChild(badges);
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

  const areaId = new URLSearchParams(location.search).get('area_id');
  const isGlobal = !areaId;
  const contextualContent = document.getElementById('contextual-events-content');
  const globalContent = document.getElementById('global-events-content');
  const message = document.getElementById(isGlobal ? 'global-message' : 'contextual-message');
  const list = document.getElementById(isGlobal ? 'global-events-list' : 'contextual-events-list');

  if (isGlobal) {
    document.body.classList.add('global-activities-page-view');
    globalContent.closest('main').classList.add('global-activities-page');
    contextualContent.hidden = true;
    globalContent.hidden = false;
  } else {
    document.getElementById('back-container').hidden = false;
    document.getElementById('section-kicker').hidden = false;
    document.getElementById('page-intro').hidden = true;
    const create = document.getElementById('new-event-link');
    create.hidden = false;
    document.getElementById('back-link').href = `area.html?area_id=${encodeURIComponent(areaId)}`;
    create.href = `nuovo-evento.html?area_id=${encodeURIComponent(areaId)}`;
  }

  const { data, error } = isGlobal
    ? await supabaseClient.rpc('get_visible_events')
    : await supabaseClient.rpc('get_area_program', { p_area_id: areaId });
  if (error) {
    message.textContent = isGlobal ? 'Impossibile caricare gli eventi visibili.' : 'Impossibile caricare il programma.';
    return;
  }
  const events = data || [];

  list.replaceChildren();
  if (isGlobal) {
    const section = document.getElementById('global-events-section');
    const empty = document.getElementById('events-empty');
    section.hidden = false;
    empty.hidden = events.length > 0;
    events.forEach((event) => list.appendChild(createGlobalRow(event)));
  } else if (!events.length) {
    message.textContent = 'Nessun elemento visibile nel programma di questa Area.';
  } else {
    events.forEach((event) => list.appendChild(createContextualCard(event, areaId)));
  }

  if (isGlobal || events.length) message.textContent = '';
}

load();
