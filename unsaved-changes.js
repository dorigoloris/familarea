(function () {
  if (window.FamilAreaUnsavedChanges) return;

  const instances = new Set();
  let pendingAction = false;

  function normalize(value) {
    if (Array.isArray(value)) return value.map(normalize);
    if (value && typeof value === 'object') {
      return Object.keys(value).sort().reduce((result, key) => {
        result[key] = normalize(value[key]);
        return result;
      }, {});
    }
    return value ?? null;
  }

  function snapshot(instance) {
    return JSON.stringify(normalize(instance.getState()));
  }

  function update(instance) {
    if (instance.disposed || !instance.isActive()) {
      instance.dirty = false;
      return false;
    }
    instance.dirty = snapshot(instance) !== instance.baseline;
    return instance.dirty;
  }

  function activeInstances() {
    return [...instances].filter((instance) => !instance.disposed && instance.isActive());
  }

  function dirtyInstances() {
    return activeInstances().filter(update);
  }

  function register({ root, getState, isActive = () => true, onDiscard = null }) {
    if (!root || typeof getState !== 'function') throw new TypeError('root e getState sono obbligatori.');
    const instance = { root, getState, isActive, onDiscard, baseline: '', dirty: false, disposed: false };
    instances.add(instance);
    capture(instance);
    return instance;
  }

  function capture(instance) {
    if (instance?.disposed) return;
    instance.baseline = snapshot(instance);
    instance.dirty = false;
  }

  function markSaved(instance) {
    capture(instance);
  }

  function reset(instance) {
    capture(instance);
  }

  function dispose(instance) {
    if (!instance) return;
    instance.disposed = true;
    instance.dirty = false;
    instances.delete(instance);
  }

  function discard(instancesToDiscard = activeInstances()) {
    instancesToDiscard.forEach((instance) => {
      instance.onDiscard?.();
      if (!instance.disposed) reset(instance);
    });
  }

  async function attempt(action, { discardActive = false } = {}) {
    if (pendingAction) return false;
    const active = activeInstances();
    if (dirtyInstances().length) {
      if (!window.FamilAreaConfirm?.confirm) return false;
      pendingAction = true;
      let confirmed = false;
      try {
        confirmed = await window.FamilAreaConfirm.confirm({
          title: 'Modifiche non salvate',
          message: 'Hai delle modifiche non salvate. Se esci ora, verranno perse.',
          cancelText: 'Continua a modificare',
          confirmText: 'Esci senza salvare'
        });
      } finally {
        pendingAction = false;
      }
      if (!confirmed) return false;
      discard(active);
      action();
      return true;
    }
    if (discardActive) discard(active);
    action();
    return true;
  }

  function updateForTarget(target) {
    instances.forEach((instance) => {
      if (!instance.disposed && instance.root.contains(target)) update(instance);
    });
  }

  function internalNavigation(event) {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.target.closest('a[href]');
    if (!link || link.target === '_blank' || link.hasAttribute('download')) return;
    const url = new URL(link.href, window.location.href);
    if (url.origin !== window.location.origin || (url.pathname === window.location.pathname && url.search === window.location.search)) return;
    if (!dirtyInstances().length) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    attempt(() => window.location.assign(url.href), { discardActive: true });
  }

  document.addEventListener('input', (event) => updateForTarget(event.target));
  document.addEventListener('change', (event) => updateForTarget(event.target));
  document.addEventListener('click', internalNavigation, true);
  window.addEventListener('beforeunload', (event) => {
    if (!dirtyInstances().length) return;
    event.preventDefault();
    event.returnValue = true;
  });

  window.FamilAreaUnsavedChanges = { register, capture, markSaved, reset, dispose, attempt };
}());
