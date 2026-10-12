const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const m = document.getElementById('deadlines-message');
const list = document.getElementById('active-deadlines-list');
const contextContainer = document.getElementById('managed-context');
const formatDateDisplay = window.FamilAreaDateUtils.formatDateDisplay;
const deadlineItemImageService = window.FamilAreaDeadlineItemImage;
const deadlineListToggle = document.getElementById('deadline-list-toggle');
const deadlineListToggleButton = document.getElementById('deadline-list-toggle-button');
const initialDeadlineLimit = 5;
let loadedDeadlines = [];
let loadedDeadlineContext = { isManaged: false, member: null };

function localDateFromIso(value) {
  const match = typeof value === 'string' && value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) return null;
  const date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  return date.getFullYear() === Number(match[1]) && date.getMonth() === Number(match[2]) - 1 && date.getDate() === Number(match[3]) ? date : null;
}

function todayLocalDate() {
  const now = new Date();
  return new Date(now.getFullYear(), now.getMonth(), now.getDate());
}

function addMonthsOnDeadlineDay(date, months) {
  const targetMonth = date.getMonth() + months;
  const year = date.getFullYear() + Math.floor(targetMonth / 12);
  const month = ((targetMonth % 12) + 12) % 12;
  const lastDay = new Date(year, month + 1, 0).getDate();
  return new Date(year, month, Math.min(date.getDate(), lastDay));
}

function isoDate(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function nextUpcomingDeadlineDate(deadline, today) {
  const firstDueOn = localDateFromIso(deadline.first_due_on);
  const terminatedOn = deadline.terminated_on ? localDateFromIso(deadline.terminated_on) : null;
  const recurrenceMonths = Number(deadline.recurrence_months);
  if (!firstDueOn || (deadline.terminated_on && !terminatedOn)) return null;
  if (!Number.isInteger(recurrenceMonths) || recurrenceMonths <= 0) return firstDueOn >= today ? firstDueOn : null;

  const monthDistance = (today.getFullYear() - firstDueOn.getFullYear()) * 12 + today.getMonth() - firstDueOn.getMonth();
  let occurrence = addMonthsOnDeadlineDay(firstDueOn, Math.max(0, Math.floor(monthDistance / recurrenceMonths)) * recurrenceMonths);
  while (occurrence < today) occurrence = addMonthsOnDeadlineDay(occurrence, recurrenceMonths);
  return terminatedOn && occurrence > terminatedOn ? null : occurrence;
}

function upcomingDeadlines(deadlines) {
  const today = todayLocalDate();
  return deadlines
    .map((deadline) => {
      const nextDueOn = nextUpcomingDeadlineDate(deadline, today);
      return nextDueOn ? { ...deadline, first_due_on: isoDate(nextDueOn) } : null;
    })
    .filter(Boolean)
    .sort((left, right) => left.first_due_on.localeCompare(right.first_due_on));
}

async function openHomeItem(event) {
  event.preventDefault();
  const { data, error } = await c.rpc('ensure_my_home_item');
  if (error || !data?.id) { m.textContent = 'Impossibile aprire Casa.'; return; }
  location.href = `gestione-scadenza-item.html?item_id=${encodeURIComponent(data.id)}`;
}

function deadlineRow(deadline) {
  const item = document.createElement('a');
  item.href = `nuova-scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`;
  item.className = 'fa-v2-list-row fa-v2-list-row--media';
  const thumbnail = document.createElement('span');
  const thumbnailName = deadline.deadline_item_name || deadline.title || 'Scadenza';
  thumbnail.setAttribute('aria-label', `Miniatura di ${thumbnailName}`);
  thumbnail.textContent = thumbnailName.trim().charAt(0).toLocaleUpperCase('it-IT');
  if (deadline.deadline_item_image_path) void deadlineItemImageService.render(thumbnail, deadline.deadline_item_image_path, `Foto di ${thumbnailName}`);
  const copy = document.createElement('span'); copy.textContent = `${formatDateDisplay(deadline.first_due_on)} — ${deadline.title}`;
  item.append(thumbnail, copy);
  return item;
}

function renderDeadlineRows() {
  const isExpanded = deadlineListToggleButton.getAttribute('aria-expanded') === 'true';
  const visibleRows = isExpanded ? loadedDeadlines : loadedDeadlines.slice(0, initialDeadlineLimit);
  list.replaceChildren(...visibleRows.map((deadline) => deadlineRow(deadline)));
  deadlineListToggle.hidden = loadedDeadlines.length <= initialDeadlineLimit;
  deadlineListToggleButton.replaceChildren(
    document.createTextNode(isExpanded ? 'Mostra meno ' : 'Vedi tutte '),
    Object.assign(document.createElement('span'), { textContent: isExpanded ? '↑' : '↓', ariaHidden: 'true' })
  );
}

deadlineListToggleButton.addEventListener('click', () => {
  const isExpanded = deadlineListToggleButton.getAttribute('aria-expanded') === 'true';
  deadlineListToggleButton.setAttribute('aria-expanded', String(!isExpanded));
  renderDeadlineRows();
});

async function load() {
  if (window.FamilAreaDeadlineManagementReady && !await window.FamilAreaDeadlineManagementReady) return;
  document.getElementById('home-category-link').addEventListener('click', openHomeItem);
  const context = await window.FamilAreaManagedContext.load();
  const isManaged = Boolean(context.member);
  if (context.requested && !isManaged) m.textContent = 'Il membro selezionato non è gestibile dalla tua Famiglia. Stai visualizzando le tue scadenze personali.';
  if (isManaged) {
    contextContainer.hidden = false; window.FamilAreaManagedContext.renderBar(contextContainer, context.member);
    document.getElementById('documents-category-link').href = window.FamilAreaManagedContext.withMember('gestione-scadenze-documenti.html', context.member.id);
  }
  const { data, error } = isManaged ? await c.rpc('get_my_deadlines_for_managed_member', { p_member_id: context.member.id }) : await c.rpc('get_my_deadlines');
  if (error) { m.textContent = 'Impossibile caricare le scadenze.'; return; }
  loadedDeadlines = upcomingDeadlines(Array.isArray(data) ? data : []);
  loadedDeadlineContext = { isManaged, member: context.member };
  deadlineListToggleButton.setAttribute('aria-expanded', 'false');
  const empty = document.getElementById('deadlines-empty'); empty.hidden = loadedDeadlines.length > 0; empty.replaceChildren();
  if (!loadedDeadlines.length) { const strong = document.createElement('strong'); strong.textContent = 'Nessuna prossima scadenza.'; empty.append(strong); }
  document.getElementById('active-deadlines-section').hidden = !loadedDeadlines.length;
  renderDeadlineRows();
  if (!context.requested || isManaged) m.textContent = '';
}
load();
