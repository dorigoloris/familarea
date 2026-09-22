const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const interestsMessage = document.getElementById('interests-message');
const interestsSection = document.getElementById('interests-section');
const categoriesContainer = document.getElementById('interests-categories');
const catalogEmpty = document.getElementById('interests-catalog-empty');
const proposalToggle = document.getElementById('interest-proposal-toggle');
const proposalForm = document.getElementById('interest-proposal-form');
const proposalName = document.getElementById('interest-proposal-name');
const proposalNote = document.getElementById('interest-proposal-note');
const proposalCancel = document.getElementById('interest-proposal-cancel');
const proposalSubmit = document.getElementById('interest-proposal-submit');
const proposalMessage = document.getElementById('interest-proposal-message');
let catalog = [];
let selectedInterests = [];
const pendingInterestIds = new Set();

function showMessage(text = '', isError = false) {
  interestsMessage.textContent = text;
  interestsMessage.classList.toggle('is-error', Boolean(text) && isError);
  interestsMessage.classList.toggle('is-success', Boolean(text) && !isError);
}

function showProposalMessage(text = '', isError = false) {
  proposalMessage.textContent = text;
  proposalMessage.hidden = !text;
  proposalMessage.classList.toggle('is-error', Boolean(text) && isError);
}

function closeProposalForm() {
  proposalForm.hidden = true;
  proposalToggle.setAttribute('aria-expanded', 'false');
}

function categoryGroups() {
  const groups = new Map();
  const addCategory = (interest) => {
    if (!interest?.category_id || groups.has(interest.category_id)) return;
    groups.set(interest.category_id, { id: interest.category_id, name: interest.category_name || 'Interessi', sortOrder: interest.category_sort_order ?? Number.MAX_SAFE_INTEGER, catalog: [], selected: [] });
  };
  catalog.forEach(addCategory);
  selectedInterests.forEach(addCategory);
  catalog.forEach((interest) => groups.get(interest.category_id)?.catalog.push(interest));
  selectedInterests.forEach((interest) => groups.get(interest.category_id)?.selected.push(interest));
  return [...groups.values()]
    .sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name, 'it'))
    .map((group) => {
      group.catalog.sort((a, b) => (a.interest_sort_order ?? 0) - (b.interest_sort_order ?? 0) || a.display_name.localeCompare(b.display_name, 'it'));
      group.selected.sort((a, b) => a.display_name.localeCompare(b.display_name, 'it'));
      return group;
    });
}

function isSelected(interestId) { return selectedInterests.some((interest) => interest.interest_id === interestId); }

function createInterestChip(interest) {
  const chip = document.createElement('button');
  const selected = isSelected(interest.interest_id);
  chip.type = 'button';
  chip.className = `interest-chip${selected ? ' is-selected' : ''}`;
  chip.textContent = interest.display_name;
  chip.disabled = pendingInterestIds.has(interest.interest_id);
  chip.setAttribute('aria-pressed', String(selected));
  chip.setAttribute('aria-label', `${selected ? 'Rimuovi' : 'Aggiungi'} interesse ${interest.display_name}`);
  chip.addEventListener('click', () => toggleInterest(interest));
  return chip;
}

function createCustomInterestForm(group) {
  const form = document.createElement('form');
  form.className = 'interest-custom-form';
  form.hidden = true;
  const label = document.createElement('label');
  const inputId = `interest-name-${group.id}`;
  label.htmlFor = inputId;
  label.textContent = 'Nome interesse';
  const input = document.createElement('input');
  input.id = inputId;
  input.type = 'text';
  input.maxLength = 120;
  input.autocomplete = 'off';
  input.required = true;
  input.placeholder = 'Es. Sci alpinismo';
  const actions = document.createElement('div');
  actions.className = 'interest-custom-actions';
  const cancel = document.createElement('button');
  cancel.type = 'button';
  cancel.className = 'fa-button fa-button-secondary fa-button-compact';
  cancel.textContent = 'Annulla';
  cancel.addEventListener('click', () => { form.hidden = true; input.value = ''; });
  const submit = document.createElement('button');
  submit.type = 'submit';
  submit.className = 'fa-button fa-button-primary fa-button-compact';
  submit.textContent = 'Aggiungi';
  actions.append(cancel, submit);
  form.append(label, input, actions);
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const displayName = input.value.trim();
    if (!displayName) return;
    input.disabled = submit.disabled = cancel.disabled = true;
    showMessage('Aggiunta interesse in corso...');
    const { error } = await supabaseClient.rpc('add_my_interest', { p_category_id: group.id, p_display_name: displayName });
    if (error) {
      input.disabled = submit.disabled = cancel.disabled = false;
      showMessage('Non è stato possibile aggiornare i tuoi interessi. Riprova.', true);
      return;
    }
    await refreshInterests('Interesse aggiunto.');
  });
  return { form, input };
}

function createCategory(group) {
  const category = document.createElement('section');
  category.className = 'interest-category';
  const categoryHeader = document.createElement('div');
  categoryHeader.className = 'interest-category-heading';
  const heading = document.createElement('h2');
  heading.textContent = group.name;
  const chips = document.createElement('div');
  chips.className = 'interest-chips';
  const catalogIds = new Set(group.catalog.map((interest) => interest.interest_id));
  group.catalog.forEach((interest) => chips.appendChild(createInterestChip(interest)));
  group.selected.filter((interest) => !catalogIds.has(interest.interest_id)).forEach((interest) => chips.appendChild(createInterestChip(interest)));
  const addButton = document.createElement('button');
  addButton.type = 'button';
  addButton.className = 'fa-button fa-button-secondary fa-button-compact';
  addButton.textContent = '+ Aggiungi interesse';
  const { form, input } = createCustomInterestForm(group);
  addButton.addEventListener('click', () => { form.hidden = false; input.focus(); });
  categoryHeader.append(heading, addButton);
  category.append(categoryHeader, chips, form);
  return category;
}

function render() {
  const groups = categoryGroups();
  categoriesContainer.replaceChildren();
  catalogEmpty.hidden = catalog.length > 0;
  groups.forEach((group) => categoriesContainer.appendChild(createCategory(group)));
  interestsSection.hidden = false;
}

async function refreshInterests(successText = '') {
  const [{ data: catalogData, error: catalogError }, { data: selectedData, error: selectedError }] = await Promise.all([
    supabaseClient.rpc('get_interest_catalog'),
    supabaseClient.rpc('get_my_interests')
  ]);
  if (catalogError || selectedError) {
    showMessage('Impossibile caricare i tuoi interessi. Riprova più tardi.', true);
    return false;
  }
  catalog = catalogData || [];
  selectedInterests = selectedData || [];
  render();
  showMessage(successText);
  return true;
}

async function toggleInterest(interest) {
  if (pendingInterestIds.has(interest.interest_id)) return;
  const selected = isSelected(interest.interest_id);
  pendingInterestIds.add(interest.interest_id);
  render();
  showMessage(selected ? 'Rimozione interesse in corso...' : 'Aggiunta interesse in corso...');
  const { error } = selected
    ? await supabaseClient.rpc('remove_my_interest', { p_interest_id: interest.interest_id })
    : await supabaseClient.rpc('add_my_interest', { p_category_id: interest.category_id, p_display_name: interest.display_name });
  pendingInterestIds.delete(interest.interest_id);
  if (error) {
    render();
    showMessage('Non è stato possibile aggiornare i tuoi interessi. Riprova.', true);
    return;
  }
  await refreshInterests(selected ? 'Interesse rimosso.' : 'Interesse aggiunto.');
}

async function loadPage() {
  if (window.FamilAreaRequirePersonal && !await window.FamilAreaRequirePersonal()) return;
  const { data } = await supabaseClient.auth.getSession();
  if (!data?.session) { window.location.href = 'login.html'; return; }
  await refreshInterests();
}

proposalToggle.addEventListener('click', () => {
  const willOpen = proposalForm.hidden;
  proposalForm.hidden = !willOpen;
  proposalToggle.setAttribute('aria-expanded', String(willOpen));
  if (willOpen) proposalName.focus();
});

proposalCancel.addEventListener('click', () => {
  proposalForm.reset();
  closeProposalForm();
  showProposalMessage('');
});

proposalForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const proposedName = proposalName.value.trim();
  const note = proposalNote.value.trim();
  if (!proposedName || proposedName.length > 100 || note.length > 500) {
    showProposalMessage('Controlla il nome della categoria e la nota.', true);
    proposalName.focus();
    return;
  }

  proposalToggle.disabled = proposalName.disabled = proposalNote.disabled = proposalCancel.disabled = proposalSubmit.disabled = true;
  showProposalMessage('Invio proposta in corso...');
  const { error } = await supabaseClient.rpc('submit_my_interest_category_proposal', {
    p_proposed_name: proposedName,
    p_note: note || null
  });
  proposalToggle.disabled = proposalName.disabled = proposalNote.disabled = proposalCancel.disabled = proposalSubmit.disabled = false;
  if (error) {
    showProposalMessage('Non è stato possibile inviare la proposta. Riprova.', true);
    return;
  }
  proposalForm.reset();
  closeProposalForm();
  showProposalMessage('Grazie, la tua proposta è stata inviata per una futura valutazione.');
});

loadPage();
