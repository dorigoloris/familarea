const managedContextContainer = document.getElementById('managed-context');
const managedMemberMessage = document.getElementById('managed-member-message');
const managedMemberHome = document.getElementById('managed-member-home');
const avatar = document.getElementById('managed-member-avatar');
const avatarInput = document.getElementById('managed-member-avatar-input');
const avatarUpload = document.getElementById('managed-member-avatar-upload');
const avatarRemove = document.getElementById('managed-member-avatar-remove');
const avatarMessage = document.getElementById('managed-member-avatar-message');
const avatarService = window.FamilAreaFamilyMemberAvatar;
let managedMember = null;

function managedMemberKind(member) {
  if (member.member_type !== 'pet') return 'Persona · Membro della Famiglia';
  const species = { dog: 'Cane', cat: 'Gatto', other: 'Animale' }[member.pet_species] || 'Animale';
  return `${species} · Animale domestico`;
}

function setAvatarMessage(text = '', isError = false) {
  avatarMessage.textContent = text;
  avatarMessage.hidden = !text;
  avatarMessage.classList.toggle('is-error', isError);
}

function setAvatarBusy(busy) {
  avatarInput.disabled = busy;
  avatarUpload.classList.toggle('is-disabled', busy);
  avatarRemove.disabled = busy;
}

function renderAvatar() {
  const name = window.FamilAreaManagedContext.memberName(managedMember);
  avatar.replaceChildren();
  avatar.textContent = name.trim().charAt(0).toLocaleUpperCase('it-IT') || '?';
  avatar.classList.toggle('is-pet', managedMember.member_type === 'pet');
  avatarUpload.textContent = managedMember.avatar_path ? 'Cambia foto' : 'Aggiungi foto';
  avatarRemove.hidden = !managedMember.avatar_path;
  const contextAvatar = managedContextContainer.querySelector('.managed-context-avatar');
  if (contextAvatar) {
    contextAvatar.replaceChildren();
    contextAvatar.textContent = name.trim().charAt(0).toLocaleUpperCase('it-IT') || '?';
  }
  if (managedMember.avatar_path) {
    void avatarService.render(avatar, managedMember.avatar_path);
    if (contextAvatar) void avatarService.render(contextAvatar, managedMember.avatar_path);
  }
}

async function currentAccount() {
  const account = await window.FamilAreaCurrentAccount;
  if (account?.account_id) return account;
  const { data } = await window.FamilAreaSupabaseClient.rpc('get_current_account');
  return data;
}

async function uploadAvatar() {
  const file = avatarInput.files?.[0];
  avatarInput.value = '';
  if (!file || !managedMember) return;
  if (!avatarService.allowedTypes.has(file.type)) { setAvatarMessage('Scegli un’immagine JPG, PNG o WebP.', true); return; }
  if (file.size > avatarService.maxBytes) { setAvatarMessage('L’immagine deve pesare al massimo 2 MB.', true); return; }

  const account = await currentAccount();
  if (!account?.account_id) { setAvatarMessage('Impossibile verificare l’account.', true); return; }
  const path = avatarService.storagePath(account.account_id, managedMember.id);
  setAvatarBusy(true);
  setAvatarMessage('Caricamento foto in corso...');
  const client = window.FamilAreaSupabaseClient;
  const { error: uploadError } = await client.storage.from(avatarService.bucket).upload(path, file, { upsert: true, contentType: file.type });
  if (uploadError) {
    setAvatarBusy(false);
    setAvatarMessage('Impossibile caricare la foto. Riprova.', true);
    return;
  }
  const { data, error } = await client.rpc('set_my_managed_family_member_avatar', { p_member_id: managedMember.id, p_avatar_path: path });
  setAvatarBusy(false);
  if (error || !data) {
    setAvatarMessage('Foto caricata, ma non è stato possibile associarla al famigliare.', true);
    return;
  }
  managedMember.avatar_path = data.avatar_path;
  renderAvatar();
  setAvatarMessage('Foto aggiornata.');
}

async function removeAvatar() {
  if (!managedMember?.avatar_path) return;
  const path = managedMember.avatar_path;
  const client = window.FamilAreaSupabaseClient;
  setAvatarBusy(true);
  setAvatarMessage('Rimozione foto in corso...');
  const { error: storageError } = await client.storage.from(avatarService.bucket).remove([path]);
  if (storageError) {
    setAvatarBusy(false);
    setAvatarMessage('Impossibile rimuovere la foto. Riprova.', true);
    return;
  }
  const { data, error } = await client.rpc('set_my_managed_family_member_avatar', { p_member_id: managedMember.id, p_avatar_path: null });
  setAvatarBusy(false);
  if (error || !data) {
    setAvatarMessage('Foto rimossa, ma non è stato possibile aggiornare il famigliare.', true);
    return;
  }
  managedMember.avatar_path = null;
  renderAvatar();
  setAvatarMessage('Foto rimossa.');
}

async function loadManagedMemberHome() {
  const context = await window.FamilAreaManagedContext.load();
  if (!context.member) {
    managedMemberMessage.textContent = context.requested
      ? 'Il membro selezionato non è gestibile dalla tua Famiglia.'
      : 'Seleziona un membro della Famiglia da gestire.';
    return;
  }

  managedMember = context.member;
  const name = window.FamilAreaManagedContext.memberName(managedMember);
  managedContextContainer.hidden = false;
  window.FamilAreaManagedContext.renderBar(managedContextContainer, managedMember, { backHref: 'famiglia.html' });

  renderAvatar();
  document.getElementById('managed-member-title').textContent = name;
  document.getElementById('managed-member-kind').textContent = managedMemberKind(managedMember);
  document.getElementById('managed-member-name-deadlines').textContent = name;
  document.getElementById('managed-member-name-calendar').textContent = name;
  document.getElementById('managed-member-deadlines-link').href = window.FamilAreaManagedContext.withMember('scadenze.html', managedMember.id);
  document.getElementById('managed-member-calendar-link').href = window.FamilAreaManagedContext.withMember('calendario.html', managedMember.id);

  managedMemberHome.hidden = false;
  managedMemberMessage.textContent = '';
}

avatarInput.addEventListener('change', () => void uploadAvatar());
avatarRemove.addEventListener('click', () => void removeAvatar());
loadManagedMemberHome();
