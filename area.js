const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);
const message = $('message');
const areaId = params.get('area_id');
const participantsView = params.get('view') === 'participants';
const labels = { family: 'Famiglia', school: 'Scuola', sport: 'Sport', friends: 'Amici', course: 'Corso', travel: 'Viaggio', other: 'Area' };

function row(title, meta, href) {
  const link = document.createElement('a');
  link.className = 'area-compact-row';
  link.href = href;
  link.innerHTML = '<span class="area-compact-row-content"><strong></strong><span class="area-compact-row-meta"></span></span><span class="area-row-indicator" aria-hidden="true">&rarr;</span>';
  link.querySelector('strong').textContent = title;
  link.querySelector('.area-compact-row-meta').textContent = meta || '';
  return link;
}

function showProgram(data) {
  $('events-title').textContent = `Attività in ${$('area-name').textContent}`;
  $('events-section').hidden = false;
  $('events-count').textContent = data.length;
  $('events-preview').replaceChildren(...data.map((item) => row(item.title, item.description || item.location || '', `evento.html?area_id=${encodeURIComponent(areaId)}&event_id=${encodeURIComponent(item.id)}`)));
  $('events-message').textContent = data.length ? '' : 'Nessun elemento nel programma visibile.';
}

async function renderParticipants(events) {
  const people = new Map();
  await Promise.all(events.map(async (event) => {
    const { data } = await supabaseClient.rpc('get_event_participants', { p_event_id: event.id });
    (data || []).forEach((participant) => {
      const current = people.get(participant.profile_id) || { ...participant, items: [] };
      current.items.push(event.title);
      people.set(participant.profile_id, current);
    });
  }));
  $('members-list').replaceChildren(...[...people.values()].sort((a, b) => `${a.first_name} ${a.last_name}`.localeCompare(`${b.first_name} ${b.last_name}`, 'it')).map((participant) => {
    const item = document.createElement('li');
    item.className = 'area-participant-row';
    const name = document.createElement('strong');
    name.textContent = `${participant.first_name || ''} ${participant.last_name || ''}`.trim() || 'Partecipante';
    const items = document.createElement('span');
    items.className = 'area-participant-role';
    items.textContent = [...new Set(participant.items)].join(' · ');
    item.append(name, items);
    return item;
  }));
  $('participants-count').textContent = people.size;
}

async function renderAreaCover(area) {
  if (!area.image_path) return;
  const illustration = $('area-illustration');
  if (!illustration) return;
  const { data, error } = await supabaseClient.storage.from('area-images').createSignedUrl(area.image_path, 3600);
  if (error || !data?.signedUrl) return;
  const image = document.createElement('img');
  image.src = data.signedUrl;
  image.alt = '';
  illustration.replaceChildren(image);
  illustration.classList.add('has-area-cover');
}

async function load() {
  const { data: session } = await supabaseClient.auth.getSession();
  if (!session.session) { location.href = 'login.html'; return; }
  if (!areaId) { message.textContent = 'Area non specificata.'; return; }
  if (participantsView) document.body.classList.add('area-participants-view');
  $('add-program-link').href = `nuovo-evento.html?area_id=${encodeURIComponent(areaId)}`;
  const [{ data: area, error }, { data: areas }, { data: events }] = await Promise.all([
    supabaseClient.rpc('get_area', { p_area_id: areaId }),
    supabaseClient.rpc('get_my_areas'),
    supabaseClient.rpc('get_area_program', { p_area_id: areaId })
  ]);
  if (error || !area) { message.textContent = "Impossibile caricare l'Area."; return; }
  const role = (areas || []).find((item) => item.id === areaId)?.role || 'member';
  $('area-name').textContent = area.name;
  $('area-type-label').textContent = labels[area.area_type] || 'Area';
  $('area-role-badge').textContent = role === 'owner' ? 'Proprietario' : role === 'admin' ? 'Amministratore' : 'Partecipante';
  $('area-role-meta').hidden = false;
  if ($('edit-area-link')) {
    $('edit-area-link').href = `modifica-area.html?area_id=${encodeURIComponent(areaId)}`;
    $('edit-area-link').hidden = !['owner', 'admin'].includes(role);
  }
  void renderAreaCover(area);
  const areaEvents = events || [];
  if (participantsView) await renderParticipants(areaEvents);
  else showProgram(areaEvents);
  message.textContent = '';
}

load();
