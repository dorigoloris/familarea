const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const calendarUtils = window.FamilAreaCalendarUtils;
const message = document.getElementById('calendar-message');
const content = document.getElementById('calendar-content');
const title = document.getElementById('month-title');
const printTitle = document.getElementById('print-month-title');
const grid = document.getElementById('calendar-grid');
const monthView = document.getElementById('month-calendar');
const weekView = document.getElementById('week-calendar');
const dayView = document.getElementById('day-calendar');
const buttons = { month: document.getElementById('month-view'), week: document.getElementById('week-view'), day: document.getElementById('day-view') };
let view = 'month';
let month = new Date(new Date().getFullYear(), new Date().getMonth(), 1);
let week = calendarUtils.startOfWeek(new Date());
let day = new Date();
let items = [];
let areas = new Map();
let isPersonalAccount = false;
let familyCalendarShares = [];
let familyCalendarControls = [];

function bounds() {
  if (view === 'week') { const start = calendarUtils.startOfWeek(week); const end = new Date(start); end.setDate(end.getDate() + 7); return { start, end }; }
  if (view === 'day') { const start = new Date(day.getFullYear(), day.getMonth(), day.getDate()); const end = new Date(start); end.setDate(end.getDate() + 1); return { start, end }; }
  return { start: new Date(month.getFullYear(), month.getMonth(), 1), end: new Date(month.getFullYear(), month.getMonth() + 1, 1) };
}

function normalise(item) {
  return {
    ...item,
    area_name: item.area_name || (item.visibility_source === 'family' ? `${item.shared_by_display_name || 'Famiglia'} · Famiglia` : (item.area_id ? areas.get(item.area_id) : null)),
    is_all_day: Boolean(item.all_day),
    occurrence_starts_at: item.starts_at,
    occurrence_ends_at: item.ends_at,
    occurs_on: item.occurs_on || item.due_on
  };
}

function syncViewControls() {
  Object.entries(buttons).forEach(([key, button]) => { const active = key === view; button.classList.toggle('is-active', active); button.setAttribute('aria-pressed', String(active)); });
}

function render() {
  syncViewControls();
  monthView.hidden = view !== 'month'; weekView.hidden = view !== 'week'; dayView.hidden = view !== 'day';
  if (view === 'month') calendarUtils.renderMonthCalendar({ month, titleElement: title, gridElement: grid, activities: items });
  else if (view === 'week') calendarUtils.renderWeekAgenda({ weekStart: week, titleElement: title, gridElement: weekView, activities: items });
  else calendarUtils.renderDayAgenda({ day, titleElement: title, gridElement: dayView, activities: items });
}

async function load() {
  const { start, end } = bounds();
  const [{ data, error }, { data: myAreas }, { data: account }] = await Promise.all([
    supabaseClient.rpc('get_calendar_occurrences', { p_from: start.toISOString(), p_to: end.toISOString() }),
    supabaseClient.rpc('get_my_areas'),
    supabaseClient.rpc('get_current_account')
  ]);
  if (error) { message.textContent = 'Impossibile caricare il calendario.'; return; }
  areas = new Map((myAreas || []).map((area) => [area.id, area.name]));
  items = (data || []).map(normalise);
  isPersonalAccount = account?.account_type === 'personal';
  await loadFamilyCalendarControls();
  content.hidden = false; message.textContent = ''; render();
}

function calendarShareRow(share) {
  const active = share.sharing_enabled === true;
  const configured = share.sharing_configured === true;
  const row = document.createElement('article');
  row.className = 'calendar-family-sharing-row';
  const copy = document.createElement('div');
  const name = document.createElement('h3'); name.textContent = share.family_name || 'Famiglia';
  const state = document.createElement('span');
  state.className = `calendar-family-share-state${active ? ' is-active' : ' is-suspended'}`;
  state.textContent = active ? 'Attiva' : (configured ? 'Sospesa' : 'Non attiva');
  const description = document.createElement('p');
  description.textContent = active
    ? 'Gli eventi impostati su Famiglia sono visibili ai membri confermati.'
    : (configured ? 'La condivisione del Calendario è temporaneamente sospesa.' : 'Attiva la condivisione per gli eventi impostati su Famiglia.');
  copy.append(name, state, description);
  const action = document.createElement('button');
  action.type = 'button'; action.className = active ? 'secondary-button' : 'fa-button fa-button-primary';
  action.textContent = active ? 'Sospendi' : (configured ? 'Riattiva' : 'Attiva');
  action.addEventListener('click', () => void setFamilyCalendarShare(share.family_id, !active, action));
  row.append(copy, action);
  return row;
}

function renderFamilyCalendarShares() {
  const section = document.getElementById('calendar-family-sharing');
  const list = document.getElementById('calendar-family-sharing-list');
  list.replaceChildren();
  if (!isPersonalAccount || !familyCalendarShares.length) { section.hidden = true; return; }
  familyCalendarShares.forEach((share) => list.appendChild(calendarShareRow(share)));
  section.hidden = false;
}

async function loadFamilyCalendarShares() {
  familyCalendarShares = [];
  if (!isPersonalAccount) { renderFamilyCalendarShares(); return; }
  const { data, error } = await supabaseClient.rpc('get_my_family_calendar_controls');
  if (error) { console.error('get_my_family_calendar_controls failed', error); renderFamilyCalendarShares(); return; }
  familyCalendarShares = data || [];
  renderFamilyCalendarShares();
}

async function setFamilyCalendarShare(familyId, sharingEnabled, button) {
  button.disabled = true;
  const { error } = await supabaseClient.rpc('set_my_family_calendar_share_permission', { p_family_id: familyId, p_recipient_account_id: null, p_sharing_enabled: sharingEnabled });
  if (error) {
    console.error('set_my_family_calendar_share_permission failed', error);
    message.textContent = 'Non è stato possibile aggiornare la condivisione del Calendario.';
    button.disabled = false;
    return;
  }
  await load();
}

function initials(name) { return (name || '?').split(/\s+/).filter(Boolean).map((part) => part[0]).slice(0, 2).join('').toUpperCase(); }

async function renderCalendarControlAvatar(avatar, avatarPath) {
  if (!avatarPath) return;
  const { data, error } = await supabaseClient.storage.from('profile-avatars').createSignedUrl(avatarPath, 3600);
  if (error || !data?.signedUrl) return;
  const image = document.createElement('img'); image.alt = '';
  image.onload = () => { if (avatar.isConnected) avatar.replaceChildren(image); };
  image.src = data.signedUrl;
}

function compactToggle(checked, disabled, title, onChange) {
  const label = document.createElement('label'); label.className = 'calendar-family-toggle'; label.title = title;
  const input = document.createElement('input'); input.type = 'checkbox'; input.checked = checked; input.disabled = disabled; input.setAttribute('aria-label', title);
  input.addEventListener('change', () => void onChange(input)); label.appendChild(input); return label;
}

function matrixDash(title = '') { const dash = document.createElement('span'); dash.className = 'calendar-family-matrix-cell'; dash.title = title; dash.textContent = '—'; return dash; }

function compactControlRow(control) {
  const row = document.createElement('div'); row.className = 'calendar-family-control-row';
  const calendarCapable = control.calendar_capable === true;
  const identity = document.createElement('div'); identity.className = 'calendar-family-control-identity';
  const avatar = document.createElement('span'); avatar.className = 'calendar-family-control-avatar'; avatar.textContent = initials(control.display_name); identity.appendChild(avatar); void renderCalendarControlAvatar(avatar, control.avatar_path);
  const name = document.createElement('span'); name.textContent = `${control.display_name || 'Membro'}${control.is_self ? ' (Io)' : ''}`; identity.appendChild(name);
  const unavailableTitle = control.member_type === 'pet' ? 'Un animale non ha un calendario FamilArea' : `${control.display_name || 'Questa persona'} non è ancora un membro FamilArea della Famiglia`;
  const viewTitle = !calendarCapable ? unavailableTitle : (control.can_view_source ? 'Visualizza questo calendario' : `${control.display_name || 'Questa persona'} non condivide il suo calendario con te`);
  const view = !calendarCapable ? matrixDash(unavailableTitle) : compactToggle(control.view_enabled, !control.can_view_source, viewTitle, async (input) => {
    input.disabled = true;
    const { error } = await supabaseClient.rpc('set_my_calendar_view_preference', { p_source_account_id: control.member_account_id, p_family_id: control.is_self ? null : control.family_id, p_visible: input.checked });
    if (error) { message.textContent = 'Impossibile aggiornare il filtro calendario.'; input.disabled = false; return; }
    await load();
  });
  const share = !calendarCapable || control.is_self ? matrixDash(unavailableTitle) : compactToggle(control.share_enabled, false, `Condividi il mio calendario con ${control.display_name || 'questa persona'}`, async (input) => {
    input.disabled = true;
    const { error } = await supabaseClient.rpc('set_my_family_calendar_share_permission', { p_family_id: control.family_id, p_recipient_account_id: control.member_account_id, p_sharing_enabled: input.checked });
    if (error) { message.textContent = 'Impossibile aggiornare il permesso di condivisione.'; input.disabled = false; return; }
    await load();
  });
  row.append(identity, view, share); return row;
}

function renderFamilyCalendarControls() {
  const section = document.getElementById('calendar-family-sharing'); const list = document.getElementById('calendar-family-sharing-list'); list.replaceChildren();
  if (!isPersonalAccount || !familyCalendarControls.length) { section.hidden = true; return; }
  const groups = new Map(); familyCalendarControls.forEach((control) => { if (!groups.has(control.family_id)) groups.set(control.family_id, []); groups.get(control.family_id).push(control); });
  groups.forEach((controls) => {
    const group = document.createElement('div'); group.className = 'calendar-family-control-group';
    const heading = document.createElement('div'); heading.className = 'calendar-family-control-heading';
    const family = document.createElement('strong'); family.textContent = controls[0].family_name || 'Famiglia';
    heading.append(family, Object.assign(document.createElement('span'), { textContent: 'Visualizza' }), Object.assign(document.createElement('span'), { textContent: 'Attiva' }));
    group.append(heading, ...controls.map(compactControlRow)); list.appendChild(group);
  });
  section.hidden = false;
}

async function loadFamilyCalendarControls() {
  familyCalendarControls = [];
  if (!isPersonalAccount) { renderFamilyCalendarControls(); return; }
  const { data, error } = await supabaseClient.rpc('get_my_family_calendar_controls');
  if (error) { console.error('get_my_family_calendar_controls failed', error); renderFamilyCalendarControls(); return; }
  familyCalendarControls = data || []; renderFamilyCalendarControls();
}

function change(offset) {
  if (view === 'month') month = new Date(month.getFullYear(), month.getMonth() + offset, 1);
  else if (view === 'week') week.setDate(week.getDate() + 7 * offset);
  else day.setDate(day.getDate() + offset);
  void load();
}

function capitalisePrintPeriod(value) { return value.replace(/\p{L}+/gu, (word) => word.charAt(0).toLocaleUpperCase('it-IT') + word.slice(1)); }
function printPeriod() {
  const monthFormat = new Intl.DateTimeFormat('it-IT', { month: 'long', year: 'numeric' });
  if (view === 'month') return capitalisePrintPeriod(monthFormat.format(month));
  if (view === 'day') return capitalisePrintPeriod(new Intl.DateTimeFormat('it-IT', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }).format(day));
  const start = calendarUtils.startOfWeek(week); const end = new Date(start); end.setDate(end.getDate() + 6); const monthOnly = new Intl.DateTimeFormat('it-IT', { month: 'long' });
  if (start.getFullYear() !== end.getFullYear()) return capitalisePrintPeriod(`${start.getDate()} ${monthOnly.format(start)} ${start.getFullYear()} – ${end.getDate()} ${monthOnly.format(end)} ${end.getFullYear()}`);
  if (start.getMonth() !== end.getMonth()) return capitalisePrintPeriod(`${start.getDate()} ${monthOnly.format(start)} – ${end.getDate()} ${monthOnly.format(end)} ${end.getFullYear()}`);
  return capitalisePrintPeriod(`${start.getDate()} – ${end.getDate()} ${monthOnly.format(end)} ${end.getFullYear()}`);
}

function printCalendar() {
  const printClass = `calendar-print-${view}`;
  const printClasses = ['calendar-print-month', 'calendar-print-week', 'calendar-print-day'];
  const cleanup = () => document.body.classList.remove(...printClasses);
  printTitle.textContent = printPeriod(); document.body.classList.remove(...printClasses); document.body.classList.add(printClass);
  window.addEventListener('afterprint', cleanup, { once: true }); window.print();
}

document.getElementById('previous-month').onclick = () => change(-1);
document.getElementById('next-month').onclick = () => change(1);
Object.entries(buttons).forEach(([key, button]) => { button.onclick = () => { view = key; syncViewControls(); void load(); }; });
document.getElementById('today-calendar').onclick = () => { const now = new Date(); month = new Date(now.getFullYear(), now.getMonth(), 1); week = calendarUtils.startOfWeek(now); day = now; void load(); };
document.getElementById('print-calendar').onclick = printCalendar;
void load();
