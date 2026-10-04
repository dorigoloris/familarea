const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const eventQuery = new URLSearchParams(location.search);
const areaId = eventQuery.get('area_id');
const eventKind = eventQuery.get('event_kind') === 'commitment' ? 'commitment' : null;
const commitmentMode = eventQuery.get('commitment_mode');
const form = document.getElementById('event-form');
const backLink = document.getElementById('back-link');
const message = document.getElementById('message');
const eventInterestsSelector = document.getElementById('event-interests-selector');
const eventInterestsMessage = document.getElementById('event-interests-message');
const startDateInput = document.getElementById('start-date');
const startTimeInput = document.getElementById('start-time');
const endDateInput = document.getElementById('end-date');
const endTimeInput = document.getElementById('end-time');
const allDayInput = document.getElementById('all-day');
const multiDayInput = document.getElementById('multi-day');
const startTimeField = document.getElementById('start-time-field');
const endTimeField = document.getElementById('end-time-field');
const endDateField = document.getElementById('end-date-field');
const endSection = document.getElementById('event-end-section');
const endDates = document.getElementById('event-end-dates');
let isPersonalAccount = false;

function isCommitmentMultiDay() {
  return commitmentMode === 'multiday' || commitmentMode === 'multi-day';
}

function hideElement(selector) {
  document.querySelector(selector)?.setAttribute('hidden', '');
}

function configureCommitmentV2() {
  if (eventKind !== 'commitment') return;

  const page = document.querySelector('main.page-card');
  const legacyTitle = page.querySelector('h1');
  const heading = isCommitmentMultiDay() ? 'Nuovo impegno' : 'Nuovo appuntamento';
  const description = isCommitmentMultiDay()
    ? 'Inserisci le date di inizio e fine del tuo impegno.'
    : 'Inserisci data e orario del tuo appuntamento.';
  const header = document.createElement('header');
  const headerContent = document.createElement('div');
  const title = document.createElement('h1');
  const intro = document.createElement('p');

  document.body.classList.add('fa-v2-app');
  page.classList.add('fa-page', 'fa-page--wide', 'fa-v2-page', 'fa-v2-page-stack');
  backLink.closest('p')?.classList.add('account-back-link');
  backLink.removeAttribute('id');
  backLink.textContent = '← Torna agli Impegni';
  form.classList.add('fa-v2-card', 'fa-v2-section-card', 'fa-v2-form-card');
  form.querySelectorAll('input:not([type="checkbox"]):not([type="radio"]), textarea, select').forEach((field) => {
    field.classList.add(field.tagName === 'TEXTAREA' ? 'fa-v2-textarea' : field.tagName === 'SELECT' ? 'fa-v2-select' : 'fa-v2-input');
  });
  const submit = form.querySelector('[type="submit"]');
  submit?.classList.add('fa-v2-button', 'fa-v2-button--primary');
  if (submit) submit.textContent = isCommitmentMultiDay() ? 'Crea impegno' : 'Crea appuntamento';
  form.querySelectorAll('br').forEach((element) => { element.hidden = true; });

  header.className = 'fa-section-hero fa-v2-header-card fa-v2-card';
  headerContent.className = 'fa-section-hero-content';
  title.textContent = heading;
  intro.textContent = description;
  headerContent.append(title, intro);
  header.append(headerContent);
  page.insertBefore(header, message);
  legacyTitle?.remove();

  hideElement('.event-interests-fieldset');
  const optionGroups = [...document.querySelectorAll('.event-form-options')];
  optionGroups.forEach((element) => { element.hidden = true; });
  hideElement('#recurrence-fields');
  hideElement('#calendar-private-fieldset');
  hideElement('#calendar-private-spacing');
  hideElement('label[for="location"]');
  hideElement('#location');
  hideElement('#event-start-heading');
  hideElement('#event-end-heading');
  document.getElementById('recurrence-enabled').checked = false;

  if (isCommitmentMultiDay()) {
    optionGroups[0].hidden = false;
    multiDayInput.closest('label').hidden = true;
    multiDayInput.checked = true;
    allDayInput.checked = true;
    allDayInput.disabled = true;
    startTimeInput.required = false;
  } else {
    multiDayInput.checked = false;
    allDayInput.checked = false;
    startTimeInput.required = true;
  }
}

function localIso(date, time = '00:00') { return new Date(`${date}T${time}`).toISOString(); }
function localIsoWeekday(dateValue) {
  const [year, month, day] = dateValue.split('-').map(Number);
  const weekday = new Date(year, month - 1, day).getDay();
  return weekday === 0 ? 7 : weekday;
}
function setRecurrenceError(text = '') {
  const error = document.getElementById('recurrence-error');
  error.textContent = text;
  error.hidden = !text;
}
function syncRecurrenceEndMode() {
  const hasEndDate = document.querySelector('input[name="recurrence-end-mode"]:checked')?.value !== 'never';
  const until = document.getElementById('recurrence-until');
  until.disabled = !hasEndDate;
  until.hidden = !hasEndDate;
}
function recurrence(startDate) {
  if (!document.getElementById('recurrence-enabled').checked) return {};
  const hasEndDate = document.querySelector('input[name="recurrence-end-mode"]:checked')?.value !== 'never';
  const until = hasEndDate ? document.getElementById('recurrence-until').value : null;
  const interval = Number(document.getElementById('recurrence-interval').value);
  const weekdays = [...document.querySelectorAll('input[name="recurrence-weekday"]:checked')]
    .map((input) => Number(input.value)).sort((first, second) => first - second);
  if (!Number.isInteger(interval) || interval < 1) throw new Error('Inserisci un intervallo di almeno 1 settimana.');
  if (interval > 32767) throw new Error('L’intervallo massimo è 32767 settimane.');
  if (!weekdays.length) throw new Error('Seleziona almeno un giorno della settimana.');
  if (hasEndDate && !until) throw new Error('Inserisci una data di fine ripetizione.');
  if (until && until < startDate) throw new Error('La fine della ripetizione non può precedere la data di inizio.');
  return { frequency: 'weekly', interval, weekdays, until, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'Europe/Rome' };
}

function syncMultiDayLayout() {
  const multiDay = multiDayInput.checked;
  const allDay = allDayInput.checked;
  if (multiDay && !endDateInput.value) endDateInput.value = startDateInput.value;
  startTimeField.hidden = allDay;
  endTimeField.hidden = allDay;
  endDateField.hidden = !multiDay;
  endSection.hidden = allDay && !multiDay;
  endDates.classList.toggle('is-multi-day', multiDay);
  endDates.classList.toggle('is-all-day', allDay);
}

function selectInitialWeekday() {
  if (!startDateInput.value) return;
  const selectedDays = [...document.querySelectorAll('input[name="recurrence-weekday"]:checked')];
  if (!selectedDays.length) {
    const initialDay = localIsoWeekday(startDateInput.value);
    const checkbox = document.querySelector(`input[name="recurrence-weekday"][value="${initialDay}"]`);
    if (checkbox) checkbox.checked = true;
  }
}

function buildInterval() {
  const startDate = startDateInput.value;
  const startTime = startTimeInput.value;
  const endDate = multiDayInput.checked ? endDateInput.value : startDate;
  const endTime = endTimeInput.value;
  const allDay = allDayInput.checked || !startTime;
  if (!startDate) throw new Error('Indica la data dell’evento.');
  if (multiDayInput.checked && !endDate) throw new Error('Indica la data di fine.');
  if (multiDayInput.checked && endDate <= startDate) {
    throw new Error(endDate === startDate
      ? 'Per un’attività di un solo giorno, disattiva Più giorni.'
      : 'La data di fine non può essere precedente alla data iniziale.');
  }
  if (!allDayInput.checked && endTime && !startTime) throw new Error('Indica prima l’ora di inizio.');
  if (multiDayInput.checked && !allDay && !endTime) throw new Error('Indica l’ora di fine.');

  const startsAt = localIso(startDate, allDay ? '00:00' : startTime);
  const endsAt = allDay
    ? (multiDayInput.checked ? localIso(endDate, '00:00') : startsAt)
    : endTime ? localIso(endDate, endTime) : null;
  if (endsAt && (new Date(endsAt) < new Date(startsAt)
    || (new Date(endsAt).getTime() === new Date(startsAt).getTime() && !(allDay && !multiDayInput.checked)))) {
    throw new Error('La fine deve essere successiva all’inizio.');
  }
  return { startsAt, endsAt, allDay };
}

function focusOnEnter(next) {
  return (event) => {
    if (event.key !== 'Enter') return;
    event.preventDefault();
    next()?.focus();
  };
}

async function load() {
  const { data } = await supabaseClient.auth.getSession();
  if (!data.session) { location.href = 'login.html'; return; }
  backLink.href = eventKind === 'commitment'
    ? 'impegni.html'
    : areaId ? `eventi.html?area_id=${encodeURIComponent(areaId)}` : 'eventi.html';
  const { data: account } = await supabaseClient.rpc('get_current_account');
  isPersonalAccount = account?.account_type === 'personal';
  if (eventKind !== 'commitment') {
  try {
    const categories = await window.FamilAreaEventInterests.loadCatalog();
    window.FamilAreaEventInterests.renderSelector(eventInterestsSelector, categories);
    eventInterestsMessage.hidden = true;
  } catch (_) {
    eventInterestsMessage.textContent = 'Il catalogo degli Interessi non è disponibile.';
  }
  }
  const privateFieldset = document.getElementById('calendar-private-fieldset');
  privateFieldset.hidden = eventKind === 'commitment' || !isPersonalAccount || Boolean(areaId);
  document.getElementById('calendar-private-spacing').hidden = privateFieldset.hidden;
  document.getElementById('calendar-private').checked = false;
  syncMultiDayLayout();
  syncRecurrenceEndMode();
  form.hidden = false;
  message.textContent = '';
}

document.getElementById('recurrence-enabled').addEventListener('change', (event) => {
  document.getElementById('recurrence-fields').hidden = !event.target.checked;
  if (event.target.checked) selectInitialWeekday();
  setRecurrenceError();
});
document.querySelectorAll('input[name="recurrence-end-mode"]').forEach((input) => input.addEventListener('change', () => {
  syncRecurrenceEndMode();
  setRecurrenceError();
}));
document.getElementById('recurrence-interval').addEventListener('input', () => setRecurrenceError());
document.getElementById('recurrence-until').addEventListener('input', () => setRecurrenceError());
document.querySelectorAll('input[name="recurrence-weekday"]').forEach((input) => input.addEventListener('change', () => setRecurrenceError()));
multiDayInput.addEventListener('change', syncMultiDayLayout);
allDayInput.addEventListener('change', syncMultiDayLayout);
startDateInput.addEventListener('change', () => {
  if (multiDayInput.checked && !endDateInput.value) endDateInput.value = startDateInput.value;
  selectInitialWeekday();
});
startDateInput.addEventListener('keydown', focusOnEnter(() => allDayInput.checked ? (multiDayInput.checked ? endDateInput : null) : startTimeInput));
startTimeInput.addEventListener('keydown', focusOnEnter(() => multiDayInput.checked ? endDateInput : endTimeInput));
endDateInput.addEventListener('keydown', focusOnEnter(() => allDayInput.checked ? null : endTimeInput));
endTimeInput.addEventListener('keydown', focusOnEnter(() => null));

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  let interval;
  try {
    interval = buildInterval();
  } catch (error) {
    message.textContent = error.message;
    return;
  }
  let recurrencePayload;
  try {
    recurrencePayload = recurrence(startDateInput.value);
    setRecurrenceError();
  } catch (error) {
    setRecurrenceError(error.message);
    return;
  }
  const payload = {
    p_title: document.getElementById('title').value.trim(),
    p_starts_at: interval.startsAt,
    p_ends_at: interval.endsAt,
    p_description: document.getElementById('notes').value.trim() || null,
    p_area_id: areaId || null,
    p_is_all_day: interval.allDay,
    p_location: document.getElementById('location').value.trim() || null,
    p_recurrence: recurrencePayload
  };
  if (isPersonalAccount && !areaId) {
    payload.p_calendar_private = document.getElementById('calendar-private').checked;
  }
  if (eventKind === 'commitment') payload.p_event_kind = eventKind;
  const submit = form.querySelector('[type="submit"]');
  submit.disabled = true;
  payload.p_interest_ids = eventKind === 'commitment'
    ? []
    : window.FamilAreaEventInterests.selectedIds(eventInterestsSelector);
  const { data, error } = await supabaseClient.rpc('create_event_with_interests', payload);
  submit.disabled = false;
  if (error || !data) { message.textContent = 'Impossibile creare l’evento.'; return; }
  if (eventKind === 'commitment') {
    location.href = 'impegni.html';
    return;
  }
  location.href = `evento.html${areaId ? `?area_id=${encodeURIComponent(areaId)}&` : '?'}event_id=${encodeURIComponent(data)}`;
});

configureCommitmentV2();
load();
