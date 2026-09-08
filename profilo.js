const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const profileMessage = document.getElementById('profile-message');
const profileContent = document.getElementById('profile-content');
const profileForm = document.getElementById('profile-form');
const firstNameInput = document.getElementById('profile-first-name');
const lastNameInput = document.getElementById('profile-last-name');
const emailInput = document.getElementById('profile-email');
const phoneInput = document.getElementById('profile-phone');
const birthDateInput = document.getElementById('profile-birth-date');
const saveButton = document.getElementById('profile-save-button');
const avatarImage = document.getElementById('avatar-image');
const avatarFallback = document.getElementById('avatar-fallback');
const avatarFileInput = document.getElementById('avatar-file-input');
const avatarUploadLabel = document.getElementById('avatar-upload-label');
const avatarRemoveButton = document.getElementById('avatar-remove-button');

const avatarBucket = 'profile-avatars';
const maxAvatarBytes = 2 * 1024 * 1024;
const allowedAvatarTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);

let authUser;
let profile;

function fullName() {
  return `${profile?.first_name || ''} ${profile?.last_name || ''}`.trim() || 'Utente';
}

function initials() {
  const parts = [profile?.first_name, profile?.last_name]
    .map((value) => (value || '').trim())
    .filter(Boolean);
  return parts.map((part) => part.charAt(0).toLocaleUpperCase('it-IT')).join('').slice(0, 2) || 'U';
}

function showMessage(text, isError = false) {
  profileMessage.textContent = text;
  profileMessage.classList.toggle('is-error', isError);
  profileMessage.classList.toggle('is-success', Boolean(text) && !isError);
}

function renderAvatarFallback() {
  avatarImage.hidden = true;
  avatarImage.removeAttribute('src');
  avatarFallback.textContent = initials();
  avatarFallback.hidden = false;
  avatarUploadLabel.textContent = profile?.avatar_path ? 'Sostituisci foto' : 'Aggiungi foto';
  avatarRemoveButton.hidden = !profile?.avatar_path;
}

async function renderAvatar() {
  if (!profile?.avatar_path) {
    renderAvatarFallback();
    return;
  }

  const { data, error } = await supabaseClient.storage
    .from(avatarBucket)
    .createSignedUrl(profile.avatar_path, 60 * 60);

  if (error || !data?.signedUrl) {
    renderAvatarFallback();
    return;
  }

  avatarImage.src = `${data.signedUrl}${data.signedUrl.includes('?') ? '&' : '?'}v=${Date.now()}`;
  avatarImage.alt = `Foto profilo di ${fullName()}`;
  avatarImage.hidden = false;
  avatarFallback.hidden = true;
  avatarUploadLabel.textContent = 'Sostituisci foto';
  avatarRemoveButton.hidden = false;
}

function fillForm(privateProfile) {
  firstNameInput.value = profile.first_name || '';
  lastNameInput.value = profile.last_name || '';
  emailInput.value = authUser.email || '';
  phoneInput.value = privateProfile?.phone || '';
  birthDateInput.value = privateProfile?.birth_date || '';
}

async function loadProfile() {
  const { data: userData, error: userError } = await supabaseClient.auth.getUser();
  authUser = userData?.user;
  if (userError || !authUser) {
    window.location.href = 'login.html';
    return;
  }

  const { data: profileData, error: profileError } = await supabaseClient
    .from('profiles')
    .select('id, first_name, last_name, avatar_path')
    .eq('user_id', authUser.id)
    .single();

  if (profileError || !profileData) {
    showMessage('Il profilo del tuo account non è disponibile. Riprova più tardi.', true);
    return;
  }

  profile = profileData;
  const { data: privateProfile, error: privateError } = await supabaseClient
    .from('account_profile_private')
    .select('phone, birth_date')
    .eq('profile_id', profile.id)
    .maybeSingle();

  if (privateError) {
    showMessage('Impossibile caricare i dati privati del profilo. Riprova più tardi.', true);
    return;
  }

  fillForm(privateProfile);
  await renderAvatar();
  profileContent.hidden = false;
  showMessage('');
}

async function saveProfile(event) {
  event.preventDefault();
  const firstName = firstNameInput.value.trim();
  const lastName = lastNameInput.value.trim() || null;

  if (!firstName) {
    showMessage('Il nome è obbligatorio.', true);
    firstNameInput.focus();
    return;
  }

  saveButton.disabled = true;
  showMessage('Salvataggio in corso...');

  const { error: profileError } = await supabaseClient
    .from('profiles')
    .update({ first_name: firstName, last_name: lastName })
    .eq('id', profile.id);

  if (profileError) {
    saveButton.disabled = false;
    showMessage('Impossibile salvare le informazioni del profilo.', true);
    return;
  }

  const { error: privateError } = await supabaseClient
    .from('account_profile_private')
    .upsert({
      profile_id: profile.id,
      phone: phoneInput.value.trim() || null,
      birth_date: birthDateInput.value || null
    }, { onConflict: 'profile_id' });

  saveButton.disabled = false;
  if (privateError) {
    profile.first_name = firstName;
    profile.last_name = lastName;
    renderAvatarFallback();
    showMessage('Nome e cognome sono stati salvati, ma non è stato possibile salvare i dati privati.', true);
    return;
  }

  profile.first_name = firstName;
  profile.last_name = lastName;
  await renderAvatar();
  showMessage('Modifiche salvate correttamente.');
}

function setAvatarBusy(isBusy, label) {
  avatarFileInput.disabled = isBusy;
  avatarUploadLabel.classList.toggle('is-disabled', isBusy);
  avatarRemoveButton.disabled = isBusy;
  if (label) avatarUploadLabel.textContent = label;
}

async function uploadAvatar() {
  const file = avatarFileInput.files?.[0];
  avatarFileInput.value = '';
  if (!file) return;

  if (!allowedAvatarTypes.has(file.type)) {
    showMessage('Scegli una foto JPG, PNG o WebP.', true);
    return;
  }
  if (file.size > maxAvatarBytes) {
    showMessage('La foto deve pesare al massimo 2 MB.', true);
    return;
  }

  const path = `${profile.id}/avatar`;
  setAvatarBusy(true, 'Caricamento...');
  showMessage('Caricamento foto in corso...');

  const { error: uploadError } = await supabaseClient.storage
    .from(avatarBucket)
    .upload(path, file, { upsert: true, contentType: file.type });

  if (uploadError) {
    setAvatarBusy(false);
    avatarUploadLabel.textContent = profile.avatar_path ? 'Sostituisci foto' : 'Aggiungi foto';
    showMessage('Impossibile caricare la foto. Riprova.', true);
    return;
  }

  const { error: profileError } = await supabaseClient
    .from('profiles')
    .update({ avatar_path: path })
    .eq('id', profile.id);

  setAvatarBusy(false);
  if (profileError) {
    avatarUploadLabel.textContent = profile.avatar_path ? 'Sostituisci foto' : 'Aggiungi foto';
    showMessage('La foto è stata caricata, ma non è stato possibile associarla al profilo. Riprova.', true);
    return;
  }

  profile.avatar_path = path;
  await renderAvatar();
  showMessage('Foto profilo aggiornata.');
}

async function removeAvatar() {
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'standard',
    title: 'Rimuovere la foto profilo?',
    message: 'Al suo posto verranno mostrate le tue iniziali.',
    confirmText: 'Rimuovi foto'
  });
  if (!confirmed) return;

  const path = profile.avatar_path;
  setAvatarBusy(true, 'Rimozione...');
  showMessage('Rimozione foto in corso...');

  if (path) {
    await supabaseClient.storage.from(avatarBucket).remove([path]);
  }

  const { error } = await supabaseClient
    .from('profiles')
    .update({ avatar_path: null })
    .eq('id', profile.id);

  setAvatarBusy(false);
  if (error) {
    avatarUploadLabel.textContent = 'Sostituisci foto';
    showMessage('Impossibile completare la rimozione della foto. Riprova.', true);
    return;
  }

  profile.avatar_path = null;
  renderAvatarFallback();
  showMessage('Foto profilo rimossa.');
}

profileForm.addEventListener('submit', saveProfile);
avatarFileInput.addEventListener('change', uploadAvatar);
avatarRemoveButton.addEventListener('click', removeAvatar);

loadProfile();
