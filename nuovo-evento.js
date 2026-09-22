const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const form = document.getElementById('event-form');
const participants = document.getElementById('participants');
const allDay = document.getElementById('all-day');
const visibilityInputs = [...document.querySelectorAll('input[name="visibility"]')];
let areaId;
const selected = () => [...participants.querySelectorAll('input:checked')].map((input) => input.value);
const visibility = () => visibilityInputs.find((input) => input.checked)?.value;
function iso(date, time, end = false) { return !date ? null : new Date(`${date}T${time || (end ? '23:59' : '00:00')}`).toISOString(); }
function updateUi() { const personal = !areaId; document.querySelector('fieldset').hidden = personal; document.getElementById('participants-fieldset').hidden = personal || visibility() === 'private'; document.getElementById('start-time').disabled = allDay.checked; document.getElementById('end-time').disabled = allDay.checked; }
async function load() {
  const { data: session } = await supabaseClient.auth.getSession(); if (!session.session) { location.href = 'login.html'; return; }
  areaId = new URLSearchParams(location.search).get('area_id'); document.getElementById('back-link').href = areaId ? `eventi.html?area_id=${encodeURIComponent(areaId)}` : 'eventi.html';
  if (!areaId) { form.hidden = false; message.textContent = ''; updateUi(); return; }
  const { data: members, error } = await supabaseClient.from('area_memberships').select('profile_id,profiles(first_name,last_name)').eq('area_id', areaId);
  if (error) { message.textContent = 'Non sei autorizzato a creare eventi in questa Area.'; return; }
  (members || []).forEach((member) => { const label = document.createElement('label'); const input = document.createElement('input'); input.type = 'checkbox'; input.value = member.profile_id; label.append(input, ` ${(member.profiles?.first_name || '')} ${(member.profiles?.last_name || '')}`.trim()); participants.append(label, document.createElement('br')); });
  form.hidden = false; message.textContent = ''; updateUi();
}
visibilityInputs.forEach((input) => input.addEventListener('change', updateUi)); allDay.addEventListener('change', updateUi);
form.addEventListener('submit', async (event) => {
  event.preventDefault(); const date = document.getElementById('start-date').value; const starts = iso(date, allDay.checked ? '' : document.getElementById('start-time').value); const ends = document.getElementById('end-time').value ? iso(date, document.getElementById('end-time').value, true) : null;
  if (!starts || (ends && new Date(ends) < new Date(starts))) { message.textContent = 'Controlla data e orario.'; return; }
  const payload = { p_title: document.getElementById('title').value.trim(), p_notes: document.getElementById('notes').value.trim() || null, p_starts_at: starts, p_ends_at: ends, p_is_all_day: allDay.checked, p_location: document.getElementById('location').value.trim() || null };
  const { data, error } = areaId ? await supabaseClient.rpc('create_area_event', { p_area_id: areaId, ...payload, p_visibility: visibility(), p_participant_profile_ids: selected() }) : await supabaseClient.rpc('create_my_event', payload);
  if (error || !data) { message.textContent = 'Impossibile creare l’evento.'; return; }
  location.href = areaId ? `evento.html?area_id=${encodeURIComponent(areaId)}&event_id=${encodeURIComponent(data)}` : `evento.html?event_id=${encodeURIComponent(data)}`;
});
load();
