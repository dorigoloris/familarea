(function () {
  const body = document.body;
  const isDashboard = body.classList.contains('dashboard-page');
  const params = new URLSearchParams(window.location.search);
  const areaId = params.get('area_id');
  const path = window.location.pathname.split('/').pop() || 'mie-aree.html';
  const isActive = (names) => names.includes(path) ? ' is-active' : '';
  const areaHref = (anchor) => areaId ? `area.html?area_id=${encodeURIComponent(areaId)}${anchor || ''}` : 'mie-aree.html#areas-title';
  const eventsHref = areaId ? `eventi.html?area_id=${encodeURIComponent(areaId)}` : 'mie-aree.html#areas-title';

  let header;
  let actions;
  if (isDashboard) {
    header = document.querySelector('.app-header');
    actions = header?.querySelector('.header-actions');
    document.querySelector('.dashboard-sidebar')?.remove();
  } else {
    body.classList.add('protected-page');
    header = document.createElement('header');
    header.className = 'shared-header';
    const brand = document.createElement('a');
    brand.className = 'app-brand';
    brand.href = 'mie-aree.html';
    brand.setAttribute('aria-label', 'FamilArea, Dashboard');
    brand.append(document.createTextNode('Famil'), Object.assign(document.createElement('span'), { textContent: 'Area' }));
    actions = document.createElement('div');
    actions.className = 'header-actions';
    const account = document.createElement('span');
    account.className = 'header-user-name';
    account.hidden = true;
    actions.appendChild(account);
    const existingLogout = document.querySelector('[data-logout]');
    const logoutMessage = document.getElementById('logout-message');
    if (existingLogout) actions.appendChild(existingLogout);
    header.append(brand, actions);
    if (logoutMessage) header.appendChild(logoutMessage);
    body.prepend(header);
  }
  if (!header || !actions) return;

  const topNav = document.createElement('nav');
  topNav.className = 'shared-top-nav';
  topNav.setAttribute('aria-label', 'Navigazione principale');
  [
    { label: 'Dashboard', href: 'mie-aree.html', active: isActive(['mie-aree.html']) },
    { label: 'Le mie Aree', href: 'mie-aree.html#areas-title', active: '' },
    { label: 'Calendario', href: 'calendario.html', active: isActive(['calendario.html']) },
    { label: 'Attività', href: areaHref('#activities-section'), active: isActive(['attivita.html', 'nuova-attivita.html']) },
    { label: 'Eventi', href: eventsHref, active: isActive(['eventi.html', 'evento.html', 'nuovo-evento.html']) }
  ].forEach((item) => {
    const link = document.createElement('a');
    link.className = `top-nav-link${item.active}`;
    link.href = item.href;
    link.textContent = item.label;
    if (item.active) link.setAttribute('aria-current', 'page');
    topNav.appendChild(link);
  });
  header.insertBefore(topNav, actions);

  const account = actions.querySelector('.header-user-name');
  if (account && window.supabase && typeof SUPABASE_URL !== 'undefined' && typeof SUPABASE_KEY !== 'undefined') {
    const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
    client.auth.getUser().then(({ data }) => {
      const user = data?.user;
      const name = user?.user_metadata?.full_name || user?.user_metadata?.name || user?.email;
      if (name) { account.textContent = name; account.hidden = false; }
    });
  }

  if (!areaId) return;
  body.classList.add('has-area-context');
  const areaNav = document.createElement('nav');
  areaNav.className = 'shared-area-nav';
  areaNav.setAttribute('aria-label', 'Navigazione Area');
  areaNav.innerHTML = `<p class="shared-nav-label">AREA <span id="nav-area-name">in caricamento…</span></p>
    <a class="sidebar-link${isActive(['area.html', 'modifica-area.html'])}" href="${areaHref()}">Panoramica Area</a>
    <a class="sidebar-link${isActive(['membro.html', 'aggiungi-membro.html'])}" href="${areaHref('#members-list')}">Partecipanti</a>
    <a class="sidebar-link${isActive(['attivita.html', 'nuova-attivita.html'])}" href="${areaHref('#activities-section')}">Attività</a>
    <a class="sidebar-link${isActive(['eventi.html', 'evento.html', 'nuovo-evento.html'])}" href="${eventsHref}">Eventi e appuntamenti</a>`;
  body.prepend(areaNav);

  if (window.supabase && typeof SUPABASE_URL !== 'undefined' && typeof SUPABASE_KEY !== 'undefined') {
    const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
    client.from('areas').select('name').eq('id', areaId).single().then(({ data }) => {
      const target = document.getElementById('nav-area-name');
      if (target) target.textContent = data?.name || 'Area';
    });
  }
}());
