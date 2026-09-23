const c = window.FamilAreaSupabaseClient;
const $ = (id) => document.getElementById(id);
let family;

function showLoadError() {
  $('family-empty-state').hidden = true;
  $('family-content').hidden = true;
  $('family-message').textContent = 'Impossibile caricare la Famiglia.';
}

async function load() {
  if (!c) {
    showLoadError();
    return;
  }

  const { data: account, error: accountError } = await c.rpc('get_current_account');
  if (accountError || !account || account.account_type !== 'personal') {
    location.href = 'dashboard.html';
    return;
  }

  const { data, error } = await c.rpc('get_my_family');
  if (error) {
    console.error('get_my_family failed', error);
    showLoadError();
    return;
  }

  family = data?.family || null;

  if (!family) {
    $('family-content').hidden = true;
    $('family-empty-state').hidden = false;
    $('family-message').textContent = '';
    return;
  }

  $('family-empty-state').hidden = true;
  $('family-content').hidden = false;
  $('family-members-list').replaceChildren(...(data.members || []).map((member) => {
    const item = document.createElement('article');
    item.textContent = [member.first_name, member.last_name, member.relationship].filter(Boolean).join(' — ');
    const removeButton = document.createElement('button');
    removeButton.textContent = 'Elimina';
    removeButton.onclick = async () => {
      const result = await c.rpc('delete_family_member', { p_member_id: member.id });
      if (result.error) console.error('delete_family_member failed', result.error);
      else load();
    };
    item.append(removeButton);
    return item;
  }));
  $('family-message').textContent = '';
}

function isFamilyAlreadyExists(error) {
  return error?.code === 'P0001' && error?.message === 'family already exists';
}

$('create-family-button').onclick = async () => {
  if (!c) {
    showLoadError();
    return;
  }

  const name = await FamilAreaConfirm.prompt({
    title: 'Crea la tua Famiglia',
    message: 'Scegli un nome per il tuo nucleo familiare.',
    confirmText: 'Crea Famiglia',
    input: { label: 'Nome della Famiglia', value: 'La mia Famiglia', required: true }
  });
  if (!name?.trim()) return;

  const { error } = await c.rpc('create_family', { p_name: name.trim() });
  if (error) {
    console.error('create_family failed', error);
    if (isFamilyAlreadyExists(error)) {
      await load();
      return;
    }
    $('family-message').textContent = 'Non è stato possibile creare la tua Famiglia. Riprova.';
    return;
  }
  await load();
};

$('add-member-button').onclick = () => { $('family-member-modal').hidden = false; };
$('family-member-form').onsubmit = async (event) => {
  event.preventDefault();
  const { error } = await c.rpc('create_family_member', {
    p_first_name: $('family-member-first-name').value.trim(),
    p_relationship: $('family-member-relationship').value,
    p_member_type: $('family-member-type').value,
    p_last_name: $('family-member-last-name').value.trim() || null,
    p_birth_date: $('family-member-birth-date').value || null,
    p_pet_species: $('family-member-species').value || null,
    p_contact_id: null
  });
  if (error) {
    console.error('create_family_member failed', error);
    return;
  }
  $('family-member-modal').hidden = true;
  load();
};
$('family-member-cancel-button').onclick = () => { $('family-member-modal').hidden = true; };
$('family-member-modal-close').onclick = () => { $('family-member-modal').hidden = true; };
load();
