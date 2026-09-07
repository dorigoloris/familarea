(function () {
  if (document.body.classList.contains('dashboard-page')) return;
  const params = new URLSearchParams(window.location.search);
  const areaId = params.get('area_id');
  const path = window.location.pathname.split('/').pop();
  const active = (names) => names.includes(path) ? ' is-active' : '';
  document.body.classList.add('protected-page');

  const header = document.createElement('header');
  header.className = 'shared-header';
  header.innerHTML = '<a class="app-brand" href="mie-aree.html" aria-label="FamilArea, Dashboard">Famil<span>Area</span></a><div class="header-actions"></div>';
  const existingLogout = document.querySelector('[data-logout]');
  const logoutMessage = document.getElementById('logout-message');
  if (existingLogout) header.querySelector('.header-actions').appendChild(existingLogout);
  if (logoutMessage) header.appendChild(logoutMessage);
  document.body.prepend(header);

  const nav = document.createElement('nav');
  nav.className = 'shared-sidebar';
  nav.setAttribute('aria-label', 'Navigazione principale');
  nav.innerHTML = `<p class="shared-nav-label">MENU</p>
    <a class="sidebar-link${active(['mie-aree.html'])}" href="mie-aree.html">Dashboard</a>
    <a class="sidebar-link" href="mie-aree.html#areas-title">Le mie Aree</a>
    <a class="sidebar-link${active(['calendario.html'])}" href="calendario.html">Calendario</a>`;
  if (areaId) {
    const areaNav = document.createElement('div');
    areaNav.className = 'area-nav';
    areaNav.innerHTML = `<p class="shared-nav-label">AREA <span id="nav-area-name">in caricamento…</span></p>
      <a class="sidebar-link${active(['area.html','modifica-area.html'])}" href="area.html?area_id=${encodeURIComponent(areaId)}">Panoramica Area</a>
      <a class="sidebar-link${active(['membro.html','aggiungi-membro.html'])}" href="area.html?area_id=${encodeURIComponent(areaId)}#members-list">Membri</a>
      <a class="sidebar-link${active(['attivita.html','nuova-attivita.html'])}" href="area.html?area_id=${encodeURIComponent(areaId)}#activities-section">Attività</a>
      <a class="sidebar-link${active(['eventi.html','evento.html','nuovo-evento.html'])}" href="eventi.html?area_id=${encodeURIComponent(areaId)}">Eventi e appuntamenti</a>`;
    nav.appendChild(areaNav);
  }
  document.body.prepend(nav);

  if (areaId && window.supabase && typeof SUPABASE_URL !== 'undefined' && typeof SUPABASE_KEY !== 'undefined') {
    const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
    client.from('areas').select('name').eq('id', areaId).single().then(({ data }) => {
      const target = document.getElementById('nav-area-name');
      if (target) target.textContent = data?.name || 'Area';
    });
  }
}());
