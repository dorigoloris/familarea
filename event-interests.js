(() => {
  async function loadCatalog() {
    const { data, error } = await window.FamilAreaSupabaseClient.rpc('get_interest_catalog');
    if (error) throw error;
    const interests = data || [];
    return interests.reduce((categories, interest) => {
      let category = categories.find((item) => item.id === interest.category_id);
      if (!category) {
        category = { id: interest.category_id, name: interest.category_name, interests: [] };
        categories.push(category);
      }
      if (interest.interest_id) category.interests.push(interest);
      return categories;
    }, []);
  }

  function renderSelector(container, categories, selectedIds = []) {
    const selected = new Set(selectedIds.map(String));
    container.replaceChildren();
    categories.forEach((category) => {
      if (!category.interests.length) return;
      const group = document.createElement('fieldset');
      group.className = 'event-interest-category';
      const legend = document.createElement('legend');
      legend.textContent = category.name;
      const list = document.createElement('div');
      list.className = 'event-interest-options';
      category.interests.forEach((interest) => {
        const label = document.createElement('label');
        const input = document.createElement('input');
        input.type = 'checkbox';
        input.name = 'event-interest';
        input.value = interest.interest_id;
        input.checked = selected.has(String(interest.interest_id));
        const text = document.createElement('span');
        text.textContent = interest.display_name;
        label.append(input, text);
        list.appendChild(label);
      });
      group.append(legend, list);
      container.appendChild(group);
    });
  }

  async function loadEventTags(eventId) {
    const { data, error } = await window.FamilAreaSupabaseClient.rpc('get_event_interests', { p_event_id: eventId });
    if (error) throw error;
    return data || [];
  }

  function selectedIds(container) {
    return [...container.querySelectorAll('input[name="event-interest"]:checked')].map((input) => input.value);
  }

  window.FamilAreaEventInterests = { loadCatalog, loadEventTags, renderSelector, selectedIds };
})();