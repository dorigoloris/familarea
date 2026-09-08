const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('preferences-form');
const message = document.getElementById('preferences-message');
const languageInput = document.getElementById('preference-language');
const dateFormatInput = document.getElementById('preference-date-format');
const weekStartInput = document.getElementById('preference-week-start');
const saveButton = document.getElementById('preferences-save-button');
const defaults = { language: 'it', date_format: 'DD/MM/YYYY', week_starts_on: 1 };
let profileId;

function showMessage(text, isError = false) {
  message.textContent = text;
  message.classList.toggle('is-error', isError);
  message.classList.toggle('is-success', Boolean(text) && !isError);
}

function fillForm(preferences = defaults) {
  languageInput.value = preferences.language || defaults.language;
  dateFormatInput.value = preferences.date_format || defaults.date_format;
  weekStartInput.value = String(preferences.week_starts_on ?? defaults.week_starts_on);
}

async function loadPreferences() {
  const { data: userData, error: userError } = await supabaseClient.auth.getUser();
  const user = userData?.user;
  if (userError || !user) { window.location.href = 'login.html'; return; }
  const { data: profile, error: profileError } = await supabaseClient.from('profiles').select('id').eq('user_id', user.id).single();
  if (profileError || !profile) { showMessage('Il profilo del tuo account non è disponibile. Riprova più tardi.', true); return; }
  profileId = profile.id;
  const { data: preferences, error } = await supabaseClient.from('account_preferences').select('language, date_format, week_starts_on').eq('profile_id', profileId).maybeSingle();
  if (error) { showMessage('Impossibile caricare le impostazioni. Riprova più tardi.', true); return; }
  fillForm(preferences || defaults);
  form.hidden = false;
  showMessage('');
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  saveButton.disabled = true;
  showMessage('Salvataggio in corso...');
  const { error } = await supabaseClient.from('account_preferences').upsert({
    profile_id: profileId,
    language: languageInput.value,
    date_format: dateFormatInput.value,
    week_starts_on: Number(weekStartInput.value)
  }, { onConflict: 'profile_id' });
  saveButton.disabled = false;
  if (error) { showMessage('Impossibile salvare le impostazioni. Riprova.', true); return; }
  showMessage('Impostazioni salvate correttamente.');
});

loadPreferences();
