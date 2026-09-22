const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const labels = { area: "Tutta l'Area", private: 'Solo io', creator_participants: 'Persone selezionate', active: 'Attivo', cancelled: 'Annullato', pending: 'Da confermare', accepted: 'Partecipo', declined: 'Non partecipo' };

function when(event) {
  const start = new Date(event.starts_at);
  const date = start.toLocaleDateString('it-IT');
  if (event.is_all_day) return `${date} · Tutto il giorno`;
  const time = start.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' });
  const end = event.ends_at ? ` – ${new Date(event.ends_at).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })}` : '';
  return `${date}, ${time}${end}`;
}

function createContextualCard(event, areaId) {
  const article = document.createElement('article');
  article.className = 'activity-card event-card';
  const title = document.createElement('h2');
  title.className = 'activity-card-title';
  title.textContent = event.title;
  const metadata = document.createElement('div');
  metadata.className = 'activity-card-meta';
  [['event-badge', 'Evento'], ['activity-status-badge', labels[event.status]], ['activity-type-badge', labels[event.visibility]]].forEach(([className, text]) => {
    const badge = document.createElement('span'); badge.className = className; badge.textContent = text; metadata.appendChild(badge);
  });
  const info = document.createElement('p');
  info.className = 'activity-card-due';
  const participation = event.my_participation_status || event.own_participation_status;
  info.textContent = `${when(event)}${event.location ? ` · ${event.location}` : ''}${participation ? ` · ${labels[participation]}` : ''}`;
  const open = document.createElement('a');
  open.className = 'btn activity-open-link';
  open.href = `evento.html?area_id=${encodeURIComponent(areaId)}&event_id=${encodeURIComponent(event.id || event.event_id)}`;
  open.textContent = 'Apri';
  article.append(title, metadata, info, open);
  return article;
}

function createGlobalRow(event) {
  const row = document.createElement('a');
  row.className = 'global-activity-row';
  row.href = event.area_id ? `evento.html?area_id=${encodeURIComponent(event.area_id)}&event_id=${encodeURIComponent(event.event_id)}` : `evento.html?event_id=${encodeURIComponent(event.event_id)}`;
  row.setAttribute('aria-label', `Apri evento ${event.title}`);
  const main = document.createElement('div');
  main.className = 'global-activity-main';
  const title = document.createElement('h2'); title.textContent = event.title;
  const area = document.createElement('p'); area.className = 'global-activity-area'; area.textContent = event.area_name || 'Personale';
  main.append(title, area);
  const details = document.createElement('div'); details.className = 'global-activity-details';
  const date = document.createElement('span'); date.className = 'global-activity-date'; date.textContent = `${when(event)}${event.location ? ` · ${event.location}` : ''}`;
  details.appendChild(date);
  if (event.status !== 'active') {
    const badges = document.createElement('div'); badges.className = 'global-activity-badges';
    const status = document.createElement('span'); status.className = `global-activity-status global-activity-status-${event.status}`; status.textContent = labels[event.status] || event.status;
    badges.appendChild(status); details.appendChild(badges);
  }
  row.append(main, details);
  return row;
}

async function load() {
  const { data: session } = await supabaseClient.auth.getSession();
  if (!session.session) { location.href = 'login.html'; return; }
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
    const create = document.getElementById('new-event-link'); create.hidden = false;
    document.getElementById('back-link').href = `area.html?area_id=${encodeURIComponent(areaId)}`;
    create.href = `nuovo-evento.html?area_id=${encodeURIComponent(areaId)}`;
  }
  const { data, error } = isGlobal ? await supabaseClient.rpc('get_my_visible_events') : await supabaseClient.rpc('get_area_events', { p_area_id: areaId });
  if (error) { message.textContent = 'Impossibile caricare gli eventi visibili.'; return; }
  list.replaceChildren();
  if (isGlobal) {
    const section = document.getElementById('global-events-section');
    const empty = document.getElementById('events-empty');
    section.hidden = false;
    empty.hidden = Boolean(data?.length);
    if (data?.length) data.forEach((event) => list.appendChild(createGlobalRow(event)));
  } else if (!data?.length) message.textContent = 'Nessun evento visibile in questa Area.';
  else data.forEach((event) => list.appendChild(createContextualCard(event, areaId)));
  if (isGlobal || data?.length) message.textContent = '';
}

load();
