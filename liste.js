const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const listsContainer = document.getElementById('lists-list');
const backLinkContainer = document.getElementById('back-link-container');
const backLink = document.getElementById('back-link');
const areaName = document.getElementById('area-name');
const newListLink = document.getElementById('new-list-link');

const visibilityLabels = {
  area: "Tutti i partecipanti dell'Area",
  private: 'Solo io',
  creator_participants: 'Partecipanti selezionati'
};

function progressLabel(list) {
  const total = Number(list.total_item_count || 0);
  const completed = Number(list.completed_item_count || 0);
  return total ? `${completed} di ${total} completati` : 'Nessun elemento';
}

function createListCard(list, { areaId, showArea = false, showProgress = false }) {
  const article = document.createElement('article');
  article.className = 'list-card';
  const title = document.createElement('h2');
  title.textContent = list.title;
  const badge = document.createElement('span');
  badge.className = 'list-visibility-badge';
  badge.textContent = visibilityLabels[list.visibility] || 'Lista';
  article.append(title, badge);

  if (showArea) {
    const area = document.createElement('p');
    area.className = 'list-card-area';
    area.textContent = list.area_name || 'Area';
    article.appendChild(area);
  }

  if (list.description) {
    const description = document.createElement('p');
    description.className = 'list-card-description';
    description.textContent = list.description;
    article.appendChild(description);
  }

  if (showProgress) {
    const progress = document.createElement('p');
    progress.className = 'list-card-progress';
    progress.textContent = progressLabel(list);
    article.appendChild(progress);
  }

  const open = document.createElement('a');
  open.className = 'btn';
  open.textContent = 'Apri';
  open.href = `lista.html?area_id=${encodeURIComponent(areaId)}&list_id=${encodeURIComponent(list.id || list.list_id)}`;
  article.appendChild(open);
  return article;
}

function renderLists(data, options, emptyText) {
  listsContainer.replaceChildren();
  if (!data?.length) {
    const empty = document.createElement('p');
    empty.className = 'empty-state';
    empty.textContent = emptyText;
    listsContainer.appendChild(empty);
    return;
  }
  data.forEach((list) => listsContainer.appendChild(createListCard(list, options(list))));
}

async function load() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }

  const areaId = new URLSearchParams(window.location.search).get('area_id');
  if (!areaId) {
    backLinkContainer.hidden = true;
    areaName.hidden = true;
    newListLink.hidden = true;

    const { data, error } = await supabaseClient.rpc('get_my_visible_lists');
    if (error) {
      message.textContent = 'Impossibile caricare le liste visibili.';
      return;
    }

    renderLists(
      data,
      (list) => ({ areaId: list.area_id, showArea: true, showProgress: true }),
      'Non hai ancora liste visibili.'
    );
    message.textContent = '';
    return;
  }

  backLink.href = `area.html?area_id=${encodeURIComponent(areaId)}`;
  newListLink.href = `nuova-lista.html?area_id=${encodeURIComponent(areaId)}`;

  const [{ data: area }, { data, error }] = await Promise.all([
    supabaseClient.from('areas').select('name').eq('id', areaId).single(),
    supabaseClient.rpc('get_area_lists', { p_area_id: areaId })
  ]);
  areaName.textContent = area?.name || 'Area';
  if (error) {
    message.textContent = 'Impossibile caricare le liste visibili.';
    return;
  }

  renderLists(data, () => ({ areaId }), 'Nessuna lista visibile in questa Area.');
  message.textContent = '';
}

load();
