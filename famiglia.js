const familyClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const familyMessage = document.getElementById('family-message');
const emptyState = document.getElementById('family-empty-state');
const familyContent = document.getElementById('family-content');
const createFamilyButton = document.getElementById('create-family-button');
const addMemberButton = document.getElementById('add-member-button');
const membersList = document.getElementById('family-members-list');
const memberModal = document.getElementById('family-member-modal');
const memberDialog = document.getElementById('family-member-dialog');
const memberModalClose = document.getElementById('family-member-modal-close');
const memberModalTitle = document.getElementById('family-member-modal-title');
const memberFormMessage = document.getElementById('family-member-form-message');
const memberForm = document.getElementById('family-member-form');
const memberTypeInput = document.getElementById('family-member-type');
const firstNameInput = document.getElementById('family-member-first-name');
const lastNameInput = document.getElementById('family-member-last-name');
const relationshipInput = document.getElementById('family-member-relationship');
const speciesInput = document.getElementById('family-member-species');
const speciesLabelInput = document.getElementById('family-member-species-label');
const birthDateInput = document.getElementById('family-member-birth-date');
const lastNameField = document.getElementById('family-member-last-name-field');
const relationshipField = document.getElementById('family-member-relationship-field');
const speciesField = document.getElementById('family-member-species-field');
const speciesLabelField = document.getElementById('family-member-species-label-field');
const memberSaveButton = document.getElementById('family-member-save-button');
const memberCancelButton = document.getElementById('family-member-cancel-button');

let family = null;
let members = [];
let editingMember = null;
let returnFocus = null;
let modalBackgroundState = [];

function showMessage(text = '', isError = false) {
  familyMessage.textContent = text;
  familyMessage.classList.toggle('is-error', isError);
  familyMessage.hidden = !text;
}

function showFormMessage(text = '', isError = false) {
  memberFormMessage.textContent = text;
  memberFormMessage.classList.toggle('is-error', isError);
  memberFormMessage.hidden = !text;
}

function readableError(error, fallback) {
  const message = error?.message || '';
  if (/nome.*obbligatorio/i.test(message)) return 'Inserisci un nome.';
  if (/relazione.*obbligatoria/i.test(message)) return 'Seleziona una relazione.';
  if (/specie.*non valida|specie dell/i.test(message)) return 'Seleziona una specie valida.';
  if (/non puo.*modificat|non puo.*eliminat/i.test(message)) return 'Questo membro non può essere modificato o rimosso.';
  if (/famiglia.*non.*creata/i.test(message)) return 'Crea prima la tua Famiglia.';
  return fallback;
}

function memberName(member) {
  return `${member.first_name || ''} ${member.last_name || ''}`.trim() || 'Membro della Famiglia';
}

function initials(member) {
  const parts = [member.first_name, member.last_name].map((value) => (value || '').trim()).filter(Boolean);
  return parts.map((part) => part.charAt(0).toLocaleUpperCase('it-IT')).join('').slice(0, 2) || '•';
}

function formatDate(value) {
  if (!value) return '';
  const [year, month, day] = value.split('-').map(Number);
  if (!year || !month || !day) return '';
  return new Intl.DateTimeFormat('it-IT', { day: 'numeric', month: 'long', year: 'numeric' }).format(new Date(year, month - 1, day));
}

function relationshipLabel(member) {
  if (member.relationship === 'self') return 'Io';
  if (member.member_type === 'pet') return 'Animale domestico';
  return ({ partner: 'Partner', child: 'Figlio/a', parent: 'Genitore', grandparent: 'Nonno/a', sibling: 'Fratello/Sorella', other: 'Altro' })[member.relationship] || member.relationship;
}

function speciesLabel(member) {
  return ({ dog: 'Cane', cat: 'Gatto', other: member.pet_species_label || 'Altro' })[member.pet_species] || 'Animale';
}

function iconSvg(kind) {
  const path = kind === 'pet'
    ? '<path d="M7 11c-2.2 0-4-1.7-4-3.8C3 5.6 4.2 4.5 5.6 4.5c1.2 0 2.1.7 2.4 1.7.4-1 1.3-1.7 2.5-1.7 1.4 0 2.6 1.1 2.6 2.7 0 2.1-1.8 3.8-4 3.8M7.5 14c2.7-4.5 7.4-4.5 9.7 0 1.5 3.1-.6 5.5-3.7 5.5H11c-3.1 0-5-2.4-3.5-5.5ZM17.8 9.3a2 2 0 1 0 0-4M21 12a2.7 2.7 0 1 0 0-5.4"/>'
    : '<circle cx="12" cy="8" r="4"/><path d="M4 21c.8-4 3.5-6 8-6s7.2 2 8 6"/>';
  return `<svg viewBox="0 0 24 24" aria-hidden="true">${path}</svg>`;
}

function createAvatar(member) {
  const avatar = document.createElement('div');
  avatar.className = `family-member-avatar${member.member_type === 'pet' ? ' is-pet' : ''}`;
  if (member.member_type === 'pet') avatar.innerHTML = iconSvg('pet');
  else avatar.textContent = initials(member);
  if (member.relationship === 'self' && member.avatar_path) loadSelfAvatar(avatar, member);
  return avatar;
}

async function loadSelfAvatar(avatar, member) {
  const { data, error } = await familyClient.storage.from('profile-avatars').createSignedUrl(member.avatar_path, 60 * 60);
  if (error || !data?.signedUrl) return;
  const image = new Image();
  image.alt = `Foto profilo di ${memberName(member)}`;
  image.onload = () => { avatar.replaceChildren(image); avatar.classList.add('has-image'); };
  image.src = `${data.signedUrl}${data.signedUrl.includes('?') ? '&' : '?'}v=${Date.now()}`;
}

function renderMembers() {
  membersList.replaceChildren();
  members.forEach((member) => {
    const card = document.createElement('article');
    card.className = `family-member-card${member.relationship === 'self' ? ' is-self' : ''}`;
    const header = document.createElement('div');
    header.className = 'family-member-card-header';
    header.appendChild(createAvatar(member));
    const identity = document.createElement('div');
    identity.className = 'family-member-identity';
    const name = document.createElement('h3');
    name.textContent = member.relationship === 'self' ? 'Io' : memberName(member);
    const subtitle = document.createElement('p');
    subtitle.textContent = member.relationship === 'self' ? memberName(member) : relationshipLabel(member);
    identity.append(name, subtitle);
    header.appendChild(identity);
    card.appendChild(header);

    const details = document.createElement('div');
    details.className = 'family-member-details';
    const type = document.createElement('span');
    type.className = 'family-member-detail';
    type.innerHTML = iconSvg(member.member_type === 'pet' ? 'pet' : 'person');
    type.append(document.createTextNode(member.member_type === 'pet' ? speciesLabel(member) : 'Persona'));
    details.appendChild(type);
    if (member.birth_date) {
      const birth = document.createElement('span');
      birth.className = 'family-member-detail';
      birth.textContent = `Nato/a il ${formatDate(member.birth_date)}`;
      details.appendChild(birth);
    }
    card.appendChild(details);

    const actions = document.createElement('div');
    actions.className = 'family-member-actions';
    if (member.relationship === 'self') {
      const profileLink = document.createElement('a');
      profileLink.className = 'family-profile-link';
      profileLink.href = 'profilo.html';
      profileLink.textContent = 'Modifica il mio profilo';
      actions.appendChild(profileLink);
    } else {
      const edit = document.createElement('button');
      edit.type = 'button';
      edit.className = 'secondary-button';
      edit.textContent = 'Modifica';
      edit.addEventListener('click', () => openMemberEditor(member, edit));
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'family-member-remove';
      remove.textContent = 'Rimuovi';
      remove.addEventListener('click', () => removeMember(member, remove));
      actions.append(edit, remove);
    }
    card.appendChild(actions);
    membersList.appendChild(card);
  });
}

async function loadFamily() {
  showMessage('Caricamento Famiglia...');
  emptyState.hidden = true;
  familyContent.hidden = true;
  const { data, error } = await familyClient.rpc('get_my_family');
  if (error) { showMessage('Non è stato possibile caricare la tua Famiglia. Riprova.', true); return; }
  family = Array.isArray(data) ? data[0] : data;
  if (!family) { showMessage(''); emptyState.hidden = false; return; }
  const { data: memberData, error: memberError } = await familyClient.rpc('get_my_family_members');
  if (memberError) { showMessage('La Famiglia è stata trovata, ma non è stato possibile caricare i membri. Riprova.', true); return; }
  members = memberData || [];
  renderMembers();
  showMessage('');
  familyContent.hidden = false;
}

async function createFamily() {
  createFamilyButton.disabled = true;
  createFamilyButton.textContent = 'Creazione in corso...';
  const { error } = await familyClient.rpc('create_my_family');
  if (error) {
    showMessage(readableError(error, 'Non è stato possibile creare la tua Famiglia. Riprova.'), true);
    createFamilyButton.disabled = false;
    createFamilyButton.textContent = 'Crea la mia Famiglia';
    return;
  }
  await loadFamily();
  createFamilyButton.disabled = false;
  createFamilyButton.textContent = 'Crea la mia Famiglia';
}

function updateEditorFields() {
  const isPet = memberTypeInput.value === 'pet';
  lastNameField.hidden = isPet;
  relationshipField.hidden = isPet;
  speciesField.hidden = !isPet;
  speciesLabelField.hidden = !isPet || speciesInput.value !== 'other';
  lastNameInput.disabled = isPet;
  relationshipInput.disabled = isPet;
  speciesInput.disabled = !isPet;
  speciesLabelInput.disabled = !isPet || speciesInput.value !== 'other';
  speciesInput.required = isPet;
}

function validateMemberForm() {
  if (!firstNameInput.value.trim()) {
    showFormMessage('Inserisci un nome.', true);
    firstNameInput.focus();
    return false;
  }
  if (memberTypeInput.value === 'person' && !relationshipInput.value) {
    showFormMessage('Seleziona una relazione.', true);
    relationshipInput.focus();
    return false;
  }
  if (memberTypeInput.value === 'pet' && !speciesInput.value) {
    showFormMessage('Seleziona una specie.', true);
    speciesInput.focus();
    return false;
  }
  if (memberTypeInput.value === 'pet' && speciesInput.value === 'other' && !speciesLabelInput.value.trim()) {
    showFormMessage('Specifica la specie dell’animale.', true);
    speciesLabelInput.focus();
    return false;
  }
  return true;
}

function openMemberEditor(member = null, trigger = null) {
  editingMember = member;
  returnFocus = trigger || document.activeElement;
  memberForm.reset();
  memberTypeInput.value = member?.member_type || 'person';
  firstNameInput.value = member?.first_name || '';
  lastNameInput.value = member?.last_name || '';
  relationshipInput.value = ['partner', 'child', 'parent', 'grandparent', 'sibling', 'other'].includes(member?.relationship) ? member.relationship : 'other';
  speciesInput.value = member?.pet_species || 'dog';
  speciesLabelInput.value = member?.pet_species_label || '';
  birthDateInput.value = member?.birth_date || '';
  memberModalTitle.textContent = member ? 'Modifica membro' : 'Aggiungi membro';
  memberSaveButton.textContent = member ? 'Salva modifiche' : 'Aggiungi membro';
  showFormMessage('');
  updateEditorFields();
  memberModal.hidden = false;
  modalBackgroundState = [...document.body.children]
    .filter((element) => element !== memberModal)
    .map((element) => ({ element, inert: element.inert, ariaHidden: element.getAttribute('aria-hidden') }));
  modalBackgroundState.forEach(({ element }) => {
    element.inert = true;
    element.setAttribute('aria-hidden', 'true');
  });
  document.body.classList.add('family-member-modal-open');
  window.setTimeout(() => memberDialog.focus(), 0);
}

function closeMemberEditor() {
  if (memberModal.hidden) return;
  memberModal.hidden = true;
  document.body.classList.remove('family-member-modal-open');
  modalBackgroundState.forEach(({ element, inert, ariaHidden }) => {
    element.inert = inert;
    if (ariaHidden === null) element.removeAttribute('aria-hidden');
    else element.setAttribute('aria-hidden', ariaHidden);
  });
  modalBackgroundState = [];
  if (returnFocus?.focus) returnFocus.focus();
  editingMember = null;
  returnFocus = null;
}

async function saveMember(event) {
  event.preventDefault();
  if (!validateMemberForm()) return;
  const isPet = memberTypeInput.value === 'pet';
  const params = {
    p_member_type: memberTypeInput.value,
    p_first_name: firstNameInput.value.trim(),
    p_last_name: isPet ? null : (lastNameInput.value.trim() || null),
    p_relationship: isPet ? 'pet' : relationshipInput.value,
    p_birth_date: birthDateInput.value || null,
    p_pet_species: isPet ? speciesInput.value : null,
    p_pet_species_label: isPet && speciesInput.value === 'other' ? (speciesLabelInput.value.trim() || null) : null
  };
  memberSaveButton.disabled = true;
  memberSaveButton.textContent = 'Salvataggio...';
  try {
    const result = editingMember
      ? await familyClient.rpc('update_my_family_member', { p_member_id: editingMember.id, ...params })
      : await familyClient.rpc('create_my_family_member', params);
    if (result.error) {
      showFormMessage(readableError(result.error, 'Non è stato possibile salvare il membro. Riprova.'), true);
      return;
    }
    closeMemberEditor();
    await loadFamily();
  } catch (error) {
    showFormMessage(readableError(error, 'Non è stato possibile salvare il membro. Riprova.'), true);
  } finally {
    memberSaveButton.disabled = false;
    memberSaveButton.textContent = editingMember ? 'Salva modifiche' : 'Aggiungi membro';
  }
}

async function removeMember(member, trigger) {
  const confirmed = window.FamilAreaConfirm ? await window.FamilAreaConfirm.confirm({ variant: 'danger', title: 'Rimuovi membro', message: `Vuoi rimuovere ${memberName(member)} dalla tua Famiglia?`, warning: 'La rimozione riguarda soltanto questo membro familiare e non elimina alcun account.', confirmText: 'Rimuovi membro' }) : false;
  if (!confirmed) return;
  trigger.disabled = true;
  const { error } = await familyClient.rpc('delete_my_family_member', { p_member_id: member.id });
  if (error) { trigger.disabled = false; showMessage(readableError(error, 'Non è stato possibile rimuovere il membro. Riprova.'), true); return; }
  await loadFamily();
}

createFamilyButton.addEventListener('click', createFamily);
addMemberButton.addEventListener('click', () => openMemberEditor());
memberTypeInput.addEventListener('change', updateEditorFields);
speciesInput.addEventListener('change', updateEditorFields);
memberForm.addEventListener('submit', saveMember);
memberForm.noValidate = true;
memberModalClose.addEventListener('click', closeMemberEditor);
memberCancelButton.addEventListener('click', closeMemberEditor);
memberModal.addEventListener('click', (event) => { if (event.target === memberModal) closeMemberEditor(); });
document.addEventListener('keydown', (event) => {
  if (memberModal.hidden) return;
  if (event.key === 'Escape') {
    event.preventDefault();
    closeMemberEditor();
    return;
  }
  if (event.key !== 'Tab') return;
  const focusable = [...memberDialog.querySelectorAll('button:not(:disabled), input:not(:disabled), select:not(:disabled)')]
    .filter((element) => !element.closest('[hidden]'));
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  if (!first || !last) return;
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first.focus();
  }
});

(async () => {
  const { data } = await familyClient.auth.getUser();
  if (!data?.user) { window.location.href = 'login.html'; return; }
  loadFamily();
})().catch(() => showMessage('Non è stato possibile inizializzare la pagina Famiglia.', true));
