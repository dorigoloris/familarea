const deadlinesClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const deadlinesMessage = document.getElementById('deadlines-message');
const activeSection = document.getElementById('active-deadlines-section');
const activeList = document.getElementById('active-deadlines-list');
const terminatedSection = document.getElementById('terminated-deadlines-section');
const terminatedList = document.getElementById('terminated-deadlines-list');
const emptyState = document.getElementById('deadlines-empty');

const categoryLabels = { vehicle: 'Auto e veicoli', home: 'Casa', documents: 'Documenti', animals: 'Animali', contracts_subscriptions: 'Contratti e abbonamenti', other: 'Altro' };
function formatDate(value) { return value ? new Date(`${value}T00:00:00`).toLocaleDateString('it-IT') : '—'; }
function recurrenceLabel(months) { return ({ 1: 'Ogni mese', 6: 'Ogni 6 mesi', 12: 'Ogni anno', 24: 'Ogni 2 anni' })[Number(months)] || 'Non ripetere'; }
function reminderLabel(days) { return Number(days) === 0 ? 'Il giorno stesso' : `${days} giorni prima`; }
function memberName(member) { return `${member?.first_name || ''} ${member?.last_name || ''}`.trim() || (member?.member_type === 'pet' ? 'Animale domestico' : 'Membro Famiglia'); }
function addText(parent, className, text) { const element = document.createElement('p'); element.className = className; element.textContent = text; parent.appendChild(element); }

function createActiveCard(deadline, nextOccurrence, members) {
  const link = document.createElement('a'); link.className = 'deadline-card'; link.href = `scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`;
  const heading = document.createElement('div'); const title = document.createElement('h3'); title.textContent = deadline.title; const category = document.createElement('span'); category.className = 'deadline-category'; category.textContent = categoryLabels[deadline.category] || deadline.category; heading.append(title, category); link.appendChild(heading);
  if (deadline.reference) addText(link, 'deadline-reference', deadline.reference);
  if (deadline.family_member_id) addText(link, 'deadline-member', `Per: ${memberName(members.get(deadline.family_member_id))}`);
  addText(link, 'deadline-next', `Prossima scadenza: ${nextOccurrence ? formatDate(nextOccurrence.occurrence_on) : 'non disponibile'}`);
  const meta = document.createElement('div'); meta.className = 'deadline-card-meta'; ['' + recurrenceLabel(deadline.recurrence_months), `Promemoria: ${reminderLabel(deadline.reminder_days)}`].forEach((text) => { const item = document.createElement('span'); item.textContent = text; meta.appendChild(item); }); link.appendChild(meta);
  return link;
}
function createTerminatedRow(deadline, members) {
  const link = document.createElement('a'); link.className = 'deadline-card deadline-card-terminated'; link.href = `scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`;
  const text = document.createElement('div'); const title = document.createElement('h3'); title.textContent = deadline.title; text.appendChild(title); if (deadline.reference) addText(text, 'deadline-reference', deadline.reference); if (deadline.family_member_id) addText(text, 'deadline-member', `Per: ${memberName(members.get(deadline.family_member_id))}`);
  const ended = document.createElement('span'); ended.textContent = `Terminata il ${formatDate(deadline.terminated_on)}`; link.append(text, ended); return link;
}
async function loadDeadlines() {
  const { data: sessionData } = await deadlinesClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  const [deadlineResult, memberResult] = await Promise.allSettled([deadlinesClient.rpc('get_my_deadlines'), deadlinesClient.rpc('get_my_family_members')]);
  if (deadlineResult.status !== 'fulfilled' || deadlineResult.value.error) { deadlinesMessage.textContent = 'Non è stato possibile caricare le scadenze. Riprova.'; return; }
  const deadlines = deadlineResult.value.data || [];
  const members = new Map((memberResult.status === 'fulfilled' && !memberResult.value.error ? memberResult.value.data : []).map((member) => [member.id, member]));
  if (!deadlines.length) { deadlinesMessage.textContent = ''; emptyState.hidden = false; return; }
  const today = new Date(); today.setHours(0, 0, 0, 0); const until = new Date(today); until.setDate(until.getDate() + 1826);
  const { data: occurrences, error: occurrenceError } = await deadlinesClient.rpc('get_my_deadline_occurrences', { p_from: today.toISOString().slice(0, 10), p_to: until.toISOString().slice(0, 10) });
  const upcomingByDeadline = new Map();
  if (!occurrenceError) (occurrences || []).filter((item) => !item.is_completed && item.status === 'active').forEach((item) => { if (!upcomingByDeadline.has(item.deadline_id)) upcomingByDeadline.set(item.deadline_id, item); });
  const active = deadlines.filter((deadline) => deadline.status === 'active'); const terminated = deadlines.filter((deadline) => deadline.status === 'terminated');
  activeList.replaceChildren(); terminatedList.replaceChildren(); active.forEach((deadline) => activeList.appendChild(createActiveCard(deadline, upcomingByDeadline.get(deadline.id), members))); terminated.forEach((deadline) => terminatedList.appendChild(createTerminatedRow(deadline, members)));
  activeSection.hidden = !active.length; terminatedSection.hidden = !terminated.length; emptyState.hidden = true; deadlinesMessage.textContent = occurrenceError ? 'Le scadenze sono disponibili; non è stato possibile calcolare le prossime date.' : '';
}
loadDeadlines().catch(() => { deadlinesMessage.textContent = 'Non è stato possibile caricare le scadenze. Riprova.'; });
