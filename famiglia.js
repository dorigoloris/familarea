const c = window.FamilAreaSupabaseClient;
const $ = (id) => document.getElementById(id);
let family;
let contacts = [];
let manualDraft = { firstName: '', lastName: '', birthDate: '' };
let editingMember = null;
let familyOwner = null;
let familyViewer = null;
let invitingMember = null;
let pendingEditAvatarFile = null;
let pendingEditAvatarObjectUrl = null;

function showLoadError() { $('family-empty-state').hidden = true; $('family-content').hidden = true; $('family-message').textContent = 'Impossibile caricare la Famiglia.'; }
function formMessage(text = '', isError = false) { const el = $('family-member-form-message'); el.textContent = text; el.hidden = !text; el.classList.toggle('is-error', isError); }
function selectedSource() { return document.querySelector('input[name="family-member-source"]:checked')?.value || 'manual'; }
function contactLabel(contact) { const name = [contact.first_name, contact.last_name].filter(Boolean).join(' '); return [name, contact.primary_email || contact.primary_phone].filter(Boolean).join(' — '); }

function canManageFamily() { return familyViewer?.can_manage === true; }
function canUseContacts() { return familyViewer?.is_owner === true; }

function resetMemberModal() {
  $('family-member-form').reset(); contacts = []; manualDraft = { firstName: '', lastName: '', birthDate: '' };
  $('family-member-contact').replaceChildren(); formMessage(''); updateMemberMode();
}
function closeMemberModal() { $('family-member-modal').hidden = true; resetMemberModal(); }
function editFormMessage(text = '', isError = false) { const el = $('family-member-edit-message'); el.textContent = text; el.hidden = !text; el.classList.toggle('is-error', isError); }
function editAvatarMessage(text = '', isError = false) { editFormMessage(text, isError); }
function isOwnerDuplicate(member) { return Boolean(member.linked_profile_id && member.linked_profile_id === familyOwner?.profile_id); }

function isManagedMember(member) {
  return member?.member_type === 'pet' || member?.member_type === 'assisted_person';
}

function canEditManagedMemberAvatar(member = editingMember) {
  return isManagedMember(member) && member?.viewer_is_manager === true;
}

function clearEditAvatarPreview({ restoreSavedAvatar = false } = {}) {
  if (pendingEditAvatarObjectUrl) URL.revokeObjectURL(pendingEditAvatarObjectUrl);
  pendingEditAvatarFile = null;
  pendingEditAvatarObjectUrl = null;
  $('family-member-edit-avatar-input').value = '';
  $('family-member-edit-avatar-confirm').hidden = true;
  $('family-member-edit-avatar-cancel').hidden = true;
  if (restoreSavedAvatar) renderEditAvatar();
}

function renderEditAvatar() {
  const preview = $('family-member-edit-avatar-preview');
  const upload = $('family-member-edit-avatar-upload');
  const remove = $('family-member-edit-avatar-remove');
  const description = $('family-member-edit-avatar-description');
  const member = editingMember;
  if (!member) return;

  preview.classList.toggle('is-pet', member.member_type === 'pet');
  preview.replaceChildren();
  preview.textContent = memberInitials(member);
  upload.textContent = member.avatar_path ? 'Sostituisci foto' : 'Aggiungi foto';
  remove.hidden = !member.avatar_path;
  description.textContent = member.avatar_path ? 'Puoi sostituire o rimuovere la foto attuale.' : 'Aggiungi una foto del profilo gestito.';

  if (pendingEditAvatarObjectUrl) {
    const image = document.createElement('img');
    image.alt = '';
    image.src = pendingEditAvatarObjectUrl;
    preview.replaceChildren(image);
  } else if (member.avatar_path) {
    void window.FamilAreaFamilyMemberAvatar.render(preview, member.avatar_path);
  }
}

function setEditAvatarBusy(busy) {
  $('family-member-edit-avatar-input').disabled = busy;
  $('family-member-edit-avatar-upload').classList.toggle('is-disabled', busy);
  $('family-member-edit-avatar-confirm').disabled = busy;
  $('family-member-edit-avatar-cancel').disabled = busy;
  $('family-member-edit-avatar-remove').disabled = busy;
}

function previewEditAvatar() {
  const file = $('family-member-edit-avatar-input').files?.[0];
  $('family-member-edit-avatar-input').value = '';
  if (!file || !canEditManagedMemberAvatar()) return;
  const avatarService = window.FamilAreaFamilyMemberAvatar;
  if (!avatarService.allowedTypes.has(file.type)) {
    editAvatarMessage('Scegli un’immagine JPG, PNG o WebP.', true);
    return;
  }
  if (file.size > avatarService.maxBytes) {
    editAvatarMessage('L’immagine deve pesare al massimo 2 MB.', true);
    return;
  }

  clearEditAvatarPreview();
  pendingEditAvatarFile = file;
  pendingEditAvatarObjectUrl = URL.createObjectURL(file);
  $('family-member-edit-avatar-upload').hidden = true;
  $('family-member-edit-avatar-remove').hidden = true;
  $('family-member-edit-avatar-confirm').hidden = false;
  $('family-member-edit-avatar-cancel').hidden = false;
  renderEditAvatar();
  editAvatarMessage('Foto selezionata. Conferma per caricarla.');
}

async function uploadEditAvatar() {
  if (!pendingEditAvatarFile || !canEditManagedMemberAvatar()) return;
  const avatarService = window.FamilAreaFamilyMemberAvatar;
  if (!family?.owner_account_id) {
    editAvatarMessage('Impossibile verificare l’account della Famiglia.', true);
    return;
  }
  const path = avatarService.storagePath(family.owner_account_id, editingMember.id);

  setEditAvatarBusy(true);
  editAvatarMessage('Caricamento foto in corso...');
  const { error: uploadError } = await c.storage.from(avatarService.bucket).upload(path, pendingEditAvatarFile, {
    upsert: true,
    contentType: pendingEditAvatarFile.type
  });
  if (uploadError) {
    setEditAvatarBusy(false);
    editAvatarMessage('Impossibile caricare la foto. Riprova.', true);
    return;
  }

  const { data, error } = await c.rpc('set_my_managed_family_member_avatar', {
    p_member_id: editingMember.id,
    p_avatar_path: path
  });
  setEditAvatarBusy(false);
  if (error || !data) {
    editAvatarMessage('Foto caricata, ma non è stato possibile associarla al famigliare.', true);
    return;
  }

  editingMember.avatar_path = data.avatar_path;
  clearEditAvatarPreview();
  renderEditAvatar();
  editAvatarMessage('Foto aggiornata.');
  await load();
}

async function removeEditAvatar() {
  if (!editingMember?.avatar_path || !canEditManagedMemberAvatar()) return;
  const path = editingMember.avatar_path;
  setEditAvatarBusy(true);
  editAvatarMessage('Rimozione foto in corso...');
  const { error: storageError } = await c.storage.from(window.FamilAreaFamilyMemberAvatar.bucket).remove([path]);
  if (storageError) {
    setEditAvatarBusy(false);
    editAvatarMessage('Impossibile rimuovere la foto. Riprova.', true);
    return;
  }

  const { data, error } = await c.rpc('set_my_managed_family_member_avatar', {
    p_member_id: editingMember.id,
    p_avatar_path: null
  });
  setEditAvatarBusy(false);
  if (error || !data) {
    editAvatarMessage('Foto rimossa, ma non è stato possibile aggiornare il famigliare.', true);
    return;
  }

  editingMember.avatar_path = null;
  renderEditAvatar();
  editAvatarMessage('Foto rimossa.');
  await load();
}

function updateMemberMode() {
  const memberType = $('family-member-type').value;
  const isPerson = memberType === 'person';
  const isPet = memberType === 'pet';
  const isAssistedPerson = memberType === 'assisted_person';
  const isManagedMember = isPet || isAssistedPerson;
  if (isManagedMember || !canUseContacts()) document.querySelector('input[name="family-member-source"][value="manual"]').checked = true;
  const useContact = canUseContacts() && isPerson && selectedSource() === 'contact';
  $('family-member-source-field').hidden = isManagedMember || !canUseContacts();
  $('family-member-contact-field').hidden = !useContact;
  $('family-member-species-field').hidden = !isPet;
  $('family-member-species-label-field').hidden = true;
  $('family-member-first-name').closest('div').hidden = useContact;
  $('family-member-last-name-field').hidden = useContact;
  $('family-member-first-name').required = !useContact;
  $('family-member-contact').required = useContact;
  if (useContact) {
    manualDraft = { firstName: $('family-member-first-name').value, lastName: $('family-member-last-name').value, birthDate: $('family-member-birth-date').value };
    $('family-member-first-name').value = ''; $('family-member-last-name').value = ''; $('family-member-birth-date').value = '';
    void loadContacts();
  } else {
    $('family-member-contact').value = '';
    $('family-member-save-button').disabled = false;
    if (!isPet) { $('family-member-first-name').value = manualDraft.firstName; $('family-member-last-name').value = manualDraft.lastName; $('family-member-birth-date').value = manualDraft.birthDate; }
  }
}

async function loadContacts() {
  const select = $('family-member-contact'); const help = $('family-member-contact-help'); const save = $('family-member-save-button');
  if (!canUseContacts()) return;
  if (contacts.length) return;
  select.disabled = true; save.disabled = true; help.hidden = false; help.textContent = 'Caricamento contatti…';
  const { data, error } = await c.rpc('get_my_contacts');
  select.disabled = false;
  if (error) { help.textContent = 'Impossibile caricare i tuoi contatti.'; formMessage('Impossibile caricare i tuoi contatti.', true); return; }
  contacts = data || [];
  select.replaceChildren(new Option('Seleziona un contatto…', ''));
  contacts.forEach((contact) => select.add(new Option(contactLabel(contact), contact.id)));
  if (!contacts.length) { help.textContent = 'Non hai ancora contatti disponibili.'; save.disabled = true; }
  else { help.hidden = true; save.disabled = false; }
}

function applyContactSelection() {
  const contact = contacts.find((item) => item.id === $('family-member-contact').value);
  if (!contact) return;
  $('family-member-first-name').value = contact.first_name || '';
  $('family-member-last-name').value = contact.last_name || '';
  $('family-member-birth-date').value = contact.birth_date || '';
  formMessage('');
}

function memberName(member) {
  return [member.first_name, member.last_name].filter(Boolean).join(' ') || 'Membro della Famiglia';
}

function memberInitials(member) {
  const parts = [member.first_name, member.last_name].filter(Boolean);
  return (parts.map((part) => part.trim().charAt(0)).join('').slice(0, 2) || '?').toLocaleUpperCase('it-IT');
}

function relationshipLabel(member) {
  if (member.member_type === 'assisted_person') return 'Persona assistita';
  if (member.member_type === 'pet') return member.pet_species ? `${speciesLabel(member.pet_species)} · Animale domestico` : 'Animale domestico';
  return {
    partner: 'Partner', child: 'Figlio/a', parent: 'Genitore', grandparent: 'Nonno/a',
    sibling: 'Fratello/Sorella', other: 'Altro'
  }[member.relationship] || 'Membro della Famiglia';
}

function speciesLabel(species) {
  return { dog: 'Cane', cat: 'Gatto', other: 'Altro' }[species] || species;
}

function formatBirthDate(value) {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return '';
  const [year, month, day] = value.split('-');
  return `${day}/${month}/${year}`;
}

function appendMemberDetail(container, label, value) {
  if (!value) return;
  const detail = document.createElement('p');
  detail.className = 'family-member-detail-row';
  const labelElement = document.createElement('span');
  labelElement.textContent = `${label}: `;
  const valueElement = document.createElement('span');
  valueElement.textContent = value;
  detail.append(labelElement, valueElement);
  container.append(detail);
}

async function renderProfileAvatar(avatar, avatarPath) {
  if (!avatarPath) return;
  const fallback = avatar.textContent;
  const { data, error } = await c.storage.from('profile-avatars').createSignedUrl(avatarPath, 3600);
  if (error || !data?.signedUrl) return;
  const image = document.createElement('img'); image.alt = '';
  image.onload = () => { if (avatar.isConnected) avatar.replaceChildren(image); };
  image.onerror = () => { if (avatar.isConnected) { avatar.replaceChildren(); avatar.textContent = fallback; } };
  image.src = `${data.signedUrl}${data.signedUrl.includes('?') ? '&' : '?'}v=${Date.now()}`;
}

function membershipLabel(member) {
  if (member.membership_status === 'confirmed') return 'Membro FamilArea';
  if (member.membership_status === 'pending') return 'Invito in attesa';
  return '';
}

function createMemberCard(member, options = {}) {
  const { isSelf = false, isOwnerCard = false, canManage = false } = options;
  const item = document.createElement('article');
  const isManaged = member.member_type === 'pet' || member.member_type === 'assisted_person';
  item.className = `family-member-card fa-v2-card${member.member_type === 'pet' ? ' is-pet' : ''}${member.member_type === 'assisted_person' ? ' is-assisted-person' : ''}${isManaged ? ' is-managed' : ''}${isSelf ? ' is-self' : ''}`;

  const header = document.createElement('header');
  header.className = 'family-member-card-header';
  const avatar = document.createElement('span');
  avatar.className = `family-member-avatar${member.member_type === 'pet' ? ' is-pet' : ''}`;
  avatar.setAttribute('aria-hidden', 'true');
  avatar.textContent = memberInitials(member);
  if (member.avatar_path) void window.FamilAreaFamilyMemberAvatar.render(avatar, member.avatar_path);
  else void renderProfileAvatar(avatar, member.profile_avatar_path);
  const identity = document.createElement('div');
  identity.className = 'family-member-identity';
  const name = document.createElement('h3');
  name.textContent = memberName(member);
  const relation = document.createElement('p');
  relation.textContent = isSelf ? 'Io' : (isOwnerCard ? 'Proprietario/a' : relationshipLabel(member));
  identity.append(name, relation);
  header.append(avatar, identity);

  const details = document.createElement('div');
  details.className = 'family-member-details';
  appendMemberDetail(details, 'Data di nascita', formatBirthDate(member.birth_date));
  // get_my_family non fornisce al momento contatti diretti: questi campi restano opzionali.
  appendMemberDetail(details, 'Email', member.primary_email || member.email);
  appendMemberDetail(details, 'Telefono', member.primary_phone || member.phone);
  const membership = membershipLabel(member);
  if (membership) {
    const state = document.createElement('p');
    state.className = `invite-status fa-status-badge invite-status-${member.membership_status === 'confirmed' ? 'accepted' : 'pending'}`;
    state.textContent = membership;
    details.append(state);
  }

  const actions = document.createElement('div');
  actions.className = 'family-member-actions';
  if (isSelf || isOwnerCard || !canManage) { item.append(header, details); return item; }
  if (member.member_type === 'person' && member.membership_status !== 'confirmed') {
    if (member.membership_status === 'pending' && member.pending_invite_id) {
      const revokeButton = document.createElement('button');
      revokeButton.className = 'fa-button fa-button-secondary'; revokeButton.type = 'button'; revokeButton.textContent = 'Annulla invito';
      revokeButton.onclick = async () => {
        revokeButton.disabled = true;
        const { error } = await c.rpc('revoke_family_invite', { p_invite_id: member.pending_invite_id });
        if (error) { console.error('revoke_family_invite failed', error); $('family-message').textContent = 'Non è stato possibile annullare l’invito.'; revokeButton.disabled = false; return; }
        await load();
      };
      actions.append(revokeButton);
    } else {
      const inviteButton = document.createElement('button');
      inviteButton.className = 'fa-button fa-button-secondary'; inviteButton.type = 'button'; inviteButton.textContent = 'Invita';
      inviteButton.onclick = () => { void openFamilyInviteModal(member); };
      actions.append(inviteButton);
    }
  }
  if (member.member_type === 'pet' || member.member_type === 'assisted_person') {
    const memberQuery = `?managed_member_id=${encodeURIComponent(member.id)}`;
    const deadlinesLink = document.createElement('a');
    deadlinesLink.className = 'fa-v2-button fa-v2-button--secondary';
    deadlinesLink.href = `scadenze.html${memberQuery}`;
    deadlinesLink.textContent = 'Scadenze';
    const calendarLink = document.createElement('a');
    calendarLink.className = 'fa-v2-button fa-v2-button--secondary';
    calendarLink.href = `calendario.html${memberQuery}`;
    calendarLink.textContent = 'Calendario';
    actions.append(deadlinesLink, calendarLink);
  }
  const editButton = document.createElement('button');
  editButton.className = 'fa-button fa-button-secondary family-member-edit';
  editButton.type = 'button';
  editButton.textContent = 'Modifica';
  editButton.onclick = () => openEditMemberModal(member);
  const removeButton = document.createElement('button');
  removeButton.className = 'family-member-remove';
  removeButton.type = 'button';
  removeButton.textContent = 'Elimina';
  removeButton.onclick = async () => {
    const confirmed = await FamilAreaConfirm.confirm({
      variant: 'danger',
      title: 'Elimina membro',
      message: 'Vuoi davvero eliminare questo membro dalla famiglia?',
      cancelText: 'Annulla',
      confirmText: 'Elimina'
    });
    if (!confirmed) return;
    removeButton.disabled = true;
    const result = await c.rpc('delete_family_member', { p_member_id: member.id });
    if (result.error) { console.error('delete_family_member failed', result.error); removeButton.disabled = false; }
    else load();
  };
  actions.append(editButton, removeButton);
  item.append(header, details, actions);
  return item;
}

function createOwnerCard(owner) {
  return createMemberCard({
    first_name: owner.first_name,
    last_name: owner.last_name,
    birth_date: owner.birth_date,
    profile_avatar_path: owner.avatar_path,
    linked_profile_id: owner.profile_id,
    member_type: 'person',
    relationship: 'self'
  }, { isSelf: owner.profile_id === familyViewer?.profile_id, isOwnerCard: true });
}

function populateEditRelationshipOptions() {
  const select = $('family-member-edit-relationship');
  select.replaceChildren(...Array.from($('family-member-relationship').options, (option) => new Option(option.text, option.value)));
}

function inviteFormMessage(text = '', isError = false) {
  const el = $('family-invite-message'); el.textContent = text; el.hidden = !text; el.classList.toggle('is-error', isError);
}

async function openFamilyInviteModal(member) {
  invitingMember = member;
  $('family-invite-member-name').textContent = memberName(member);
  $('family-invite-member-relationship').textContent = relationshipLabel(member);
  $('family-invite-email').value = '';
  inviteFormMessage('');
  $('family-invite-modal').hidden = false;
  $('family-invite-dialog').focus();
  if (!canUseContacts() || !member.contact_id) return;
  const { data, error } = await c.rpc('get_my_contacts');
  if (error || !invitingMember || invitingMember.id !== member.id) return;
  const contact = (data || []).find((item) => item.id === member.contact_id);
  if (contact?.primary_email) $('family-invite-email').value = contact.primary_email;
}

function closeFamilyInviteModal() {
  $('family-invite-modal').hidden = true;
  $('family-invite-form').reset();
  invitingMember = null;
  inviteFormMessage('');
}

function openEditMemberModal(member) {
  editingMember = member;
  const linkedContact = canUseContacts() && Boolean(member.contact_id);
  const name = memberName(member);
  populateEditRelationshipOptions();
  $('family-member-edit-first-name').value = member.first_name || '';
  $('family-member-edit-last-name').value = member.last_name || '';
  $('family-member-edit-relationship').value = member.relationship || 'other';
  $('family-member-edit-birth-date').value = member.birth_date || '';
  $('family-member-edit-first-name-field').hidden = linkedContact;
  $('family-member-edit-last-name-field').hidden = linkedContact;
  $('family-member-edit-first-name').required = !linkedContact;
  $('family-member-linked-contact').hidden = !linkedContact;
  $('family-member-linked-name').textContent = name;
  $('family-member-edit-intro').textContent = member.member_type === 'pet' ? 'Aggiorna le informazioni del tuo animale domestico.' : (member.member_type === 'assisted_person' ? 'Aggiorna le informazioni della persona assistita.' : 'Aggiorna le informazioni del membro.');
  const canEditAvatar = canEditManagedMemberAvatar(member);
  $('family-member-edit-avatar-field').hidden = !canEditAvatar;
  clearEditAvatarPreview();
  if (canEditAvatar) renderEditAvatar();
  editFormMessage('');
  $('family-member-edit-modal').hidden = false;
  $('family-member-edit-dialog').focus();
}

function closeEditMemberModal() {
  clearEditAvatarPreview();
  $('family-member-edit-modal').hidden = true;
  $('family-member-edit-form').reset();
  $('family-member-edit-avatar-field').hidden = true;
  editingMember = null;
  editFormMessage('');
}

async function load() {
  if (!c) return showLoadError();
  const { data: account, error: accountError } = await c.rpc('get_current_account');
  if (accountError || !account || account.account_type !== 'personal') { location.href = 'dashboard.html'; return; }
  const { data, error } = await c.rpc('get_my_family');
  if (error) { console.error('get_my_family failed', error); return showLoadError(); }
  family = data?.family || null;
  familyOwner = data?.owner || null;
  familyViewer = data?.viewer || null;
  if (!family) { $('family-content').hidden = true; $('family-empty-state').hidden = false; $('family-message').textContent = ''; return; }
  $('family-empty-state').hidden = true; $('family-content').hidden = false;
  const canManage = canManageFamily();
  $('add-member-button').hidden = !canManage;
  const members = (data.members || []).filter((member) => !isOwnerDuplicate(member));
  const people = members.filter((member) => member.member_type === 'person');
  const managedMembers = members.filter((member) => member.member_type === 'pet' || member.member_type === 'assisted_person');
  const peopleCards = familyOwner
    ? [createOwnerCard(familyOwner), ...people.map((member) => createMemberCard(member, { isSelf: member.linked_profile_id === familyViewer?.profile_id, canManage }))]
    : people.map((member) => createMemberCard(member, { isSelf: member.linked_profile_id === familyViewer?.profile_id, canManage }));
  $('family-members-list').replaceChildren(...peopleCards);
  $('family-managed-members-list').replaceChildren(...managedMembers.map((member) => createMemberCard(member, { isSelf: false, canManage: Boolean(member.viewer_is_manager) })));
  $('family-managed-members-section').hidden = managedMembers.length === 0;
  $('family-message').textContent = '';
}

function isFamilyAlreadyExists(error) { return error?.code === 'P0001' && error?.message === 'family already exists'; }
$('create-family-button').onclick = async () => {
  if (!c) return showLoadError();
  const name = await FamilAreaConfirm.prompt({ title: 'Crea la tua Famiglia', message: 'Scegli un nome per il tuo nucleo familiare.', confirmText: 'Crea Famiglia', input: { label: 'Nome della Famiglia', value: 'La mia Famiglia', required: true } });
  if (!name?.trim()) return;
  const { error } = await c.rpc('create_family', { p_name: name.trim() });
  if (error) { console.error('create_family failed', error); if (isFamilyAlreadyExists(error)) return load(); $('family-message').textContent = 'Non è stato possibile creare la tua Famiglia. Riprova.'; return; }
  await load();
};

$('add-member-button').onclick = () => { resetMemberModal(); $('family-member-modal').hidden = false; };
document.querySelectorAll('input[name="family-member-source"]').forEach((input) => input.addEventListener('change', updateMemberMode));
$('family-member-type').addEventListener('change', updateMemberMode);
$('family-member-contact').addEventListener('change', applyContactSelection);
$('family-member-form').onsubmit = async (event) => {
  event.preventDefault(); formMessage('');
  const memberType = $('family-member-type').value;
  const isPet = memberType === 'pet';
  const useContact = canUseContacts() && memberType === 'person' && selectedSource() === 'contact';
  const contactId = useContact ? $('family-member-contact').value : null;
  if (useContact && !contactId) { formMessage('Seleziona un contatto.', true); return; }
  const { error } = await c.rpc('create_family_member', {
    p_first_name: $('family-member-first-name').value.trim(), p_relationship: $('family-member-relationship').value,
    p_member_type: memberType, p_last_name: $('family-member-last-name').value.trim() || null,
    p_birth_date: $('family-member-birth-date').value || null, p_pet_species: isPet ? ($('family-member-species').value || null) : null, p_contact_id: contactId
  });
  if (error) { console.error('create_family_member failed', error); formMessage(error.message || 'Non è stato possibile salvare il membro.', true); return; }
  closeMemberModal(); load();
};
$('family-member-cancel-button').onclick = closeMemberModal;
$('family-member-modal-close').onclick = closeMemberModal;
$('family-member-edit-cancel').onclick = closeEditMemberModal;
$('family-member-edit-close').onclick = closeEditMemberModal;
$('family-member-edit-avatar-input').addEventListener('change', previewEditAvatar);
$('family-member-edit-avatar-confirm').onclick = () => void uploadEditAvatar();
$('family-member-edit-avatar-cancel').onclick = () => {
  clearEditAvatarPreview({ restoreSavedAvatar: true });
  editAvatarMessage('');
};
$('family-member-edit-avatar-remove').onclick = () => void removeEditAvatar();
$('family-member-edit-form').onsubmit = async (event) => {
  event.preventDefault();
  if (!editingMember) return;
  editFormMessage('');
  const saveButton = $('family-member-edit-save');
  saveButton.disabled = true;
  const { error } = await c.rpc('update_family_member', {
    p_member_id: editingMember.id,
    p_first_name: $('family-member-edit-first-name').value.trim(),
    p_last_name: $('family-member-edit-last-name').value.trim() || null,
    p_relationship: $('family-member-edit-relationship').value,
    p_member_type: editingMember.member_type,
    p_birth_date: $('family-member-edit-birth-date').value || null,
    p_pet_species: editingMember.member_type === 'pet' ? (editingMember.pet_species || null) : null,
    p_contact_id: canUseContacts() ? (editingMember.contact_id || null) : null
  });
  saveButton.disabled = false;
  if (error) { console.error('update_family_member failed', error); editFormMessage(error.message || 'Non è stato possibile salvare le modifiche.', true); return; }
  closeEditMemberModal();
  await load();
};
$('family-invite-cancel').onclick = closeFamilyInviteModal;
$('family-invite-close').onclick = closeFamilyInviteModal;
$('family-invite-form').onsubmit = async (event) => {
  event.preventDefault();
  if (!invitingMember) return;
  const submit = $('family-invite-submit');
  submit.disabled = true; inviteFormMessage('');
  const { error } = await c.rpc('create_family_invite', {
    p_family_member_id: invitingMember.id,
    p_recipient_email: $('family-invite-email').value.trim()
  });
  submit.disabled = false;
  if (error) { console.error('create_family_invite failed', error); inviteFormMessage(error.message || 'Non è stato possibile inviare l’invito.', true); return; }
  closeFamilyInviteModal();
  $('family-message').textContent = 'Invito inviato.';
  await load();
};
load();
