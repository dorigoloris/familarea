const utilitiesClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const utilitiesMessage = document.getElementById('utilities-message');
const utilitiesList = document.getElementById('utilities-list');
const utilitiesEmpty = document.getElementById('utilities-empty');
const formatUtilityDate = window.FamilAreaDateUtils.formatDateDisplay;

function localDate(value) {
  const match = typeof value === 'string' && /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return null;
  const date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  return date.getFullYear() === Number(match[1]) && date.getMonth() === Number(match[2]) - 1 && date.getDate() === Number(match[3]) ? date : null;
}

function isoDate(value) {
  return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, '0')}-${String(value.getDate()).padStart(2, '0')}`;
}

function addMonths(date, months) {
  const targetMonth = date.getMonth() + months;
  const year = date.getFullYear() + Math.floor(targetMonth / 12);
  const month = ((targetMonth % 12) + 12) % 12;
  return new Date(year, month, Math.min(date.getDate(), new Date(year, month + 1, 0).getDate()));
}

function recurrenceLabel(months) {
  const value = Number(months);
  if (!Number.isInteger(value) || value <= 0) return 'Non ricorrente';
  if (value === 1) return 'Ogni mese';
  if (value === 12) return 'Ogni anno';
  return `Ogni ${value} mesi`;
}

function occurrencesThroughToday(deadline, today) {
  const first = localDate(deadline.first_due_on);
  const end = deadline.terminated_on ? localDate(deadline.terminated_on) : null;
  const recurrenceMonths = Number(deadline.recurrence_months);
  if (!first || (deadline.terminated_on && !end) || first > today) return [];
  const dates = [];
  for (let occurrence = first; occurrence <= today && (!end || occurrence <= end); occurrence = addMonths(occurrence, recurrenceMonths)) {
    dates.push(occurrence);
    if (!Number.isInteger(recurrenceMonths) || recurrenceMonths <= 0) break;
  }
  return dates;
}

function nextOccurrence(deadline, today, completions) {
  const first = localDate(deadline.first_due_on);
  const end = deadline.terminated_on ? localDate(deadline.terminated_on) : null;
  const recurrenceMonths = Number(deadline.recurrence_months);
  if (!first || (deadline.terminated_on && !end)) return null;
  let occurrence = first;
  while (occurrence < today || completions.has(isoDate(occurrence))) {
    if (!Number.isInteger(recurrenceMonths) || recurrenceMonths <= 0) return null;
    occurrence = addMonths(occurrence, recurrenceMonths);
  }
  return end && occurrence > end ? null : occurrence;
}

async function decorateDeadlines(deadlines) {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const dated = deadlines.filter((deadline) => localDate(deadline.first_due_on));
  const earliest = dated.map((deadline) => localDate(deadline.first_due_on)).sort((left, right) => left - right)[0];
  const completions = new Map();
  if (earliest) {
    const { data, error } = await utilitiesClient.rpc('get_deadline_occurrences', { p_from: isoDate(earliest), p_to: isoDate(today) });
    if (error) throw error;
    (data || []).forEach((occurrence) => completions.set(`${occurrence.deadline_id}:${occurrence.occurrence_on}`, Boolean(occurrence.completed)));
  }
  return deadlines.map((deadline) => {
    const overdue = occurrencesThroughToday(deadline, today).find((date) => !completions.get(`${deadline.id}:${isoDate(date)}`));
    if (overdue && overdue < today) return { ...deadline, displayDate: overdue, overdue: true };
    const completed = new Set(occurrencesThroughToday(deadline, today)
      .filter((date) => completions.get(`${deadline.id}:${isoDate(date)}`)).map(isoDate));
    return { ...deadline, displayDate: nextOccurrence(deadline, today, completed), overdue: false };
  }).sort((left, right) => {
    if (left.overdue !== right.overdue) return left.overdue ? -1 : 1;
    return (left.displayDate?.getTime() || Number.MAX_SAFE_INTEGER) - (right.displayDate?.getTime() || Number.MAX_SAFE_INTEGER);
  });
}

function utilityRow(deadline) {
  const row = document.createElement('a');
  row.className = 'fa-v2-list-row fa-v2-list-row--media';
  row.href = `nuova-scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}&return_to=utilities`;
  const icon = document.createElement('span');
  icon.setAttribute('aria-hidden', 'true');
  icon.textContent = 'U';
  const copy = document.createElement('span');
  const title = document.createElement('strong');
  title.textContent = deadline.title || 'Utenza o bolletta';
  const meta = document.createElement('span');
  meta.className = 'fa-v2-status';
  const occurrence = deadline.displayDate ? formatUtilityDate(isoDate(deadline.displayDate)) : '';
  meta.textContent = deadline.overdue
    ? `Scaduta — da regolarizzare dal ${occurrence}`
    : occurrence ? `Prossima scadenza: ${occurrence}` : 'Nessuna prossima occorrenza';
  const recurrence = document.createElement('span');
  recurrence.className = 'fa-v2-status';
  recurrence.textContent = recurrenceLabel(deadline.recurrence_months);
  copy.append(title, meta, recurrence);
  const action = document.createElement('span');
  action.className = 'fa-v2-button fa-v2-button--secondary';
  action.textContent = 'Apri';
  row.append(icon, copy, action);
  return row;
}

async function loadUtilities() {
  if (!await window.FamilAreaDeadlineManagementReady) return;
  const { data, error } = await utilitiesClient.rpc('get_my_deadlines');
  if (error) {
    utilitiesMessage.textContent = 'Impossibile caricare utenze e bollette.';
    return;
  }
  const utilities = (data || []).filter((deadline) => deadline.category === 'utilities');
  let rows;
  try {
    rows = await decorateDeadlines(utilities);
  } catch (error) {
    console.error('get_deadline_occurrences failed for utilities', error);
    utilitiesMessage.textContent = 'Impossibile verificare le occorrenze delle utenze.';
    return;
  }
  utilitiesList.replaceChildren(...rows.map(utilityRow));
  utilitiesEmpty.hidden = rows.length > 0;
  utilitiesList.hidden = rows.length === 0;
  utilitiesMessage.textContent = '';
}

void loadUtilities();
