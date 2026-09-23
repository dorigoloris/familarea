(function () {
  let activeModal = null;

  function createElement(tagName, className, text) {
    const element = document.createElement(tagName);
    if (className) element.className = className;
    if (text) element.textContent = text;
    return element;
  }

  function openModal(options) {
    if (activeModal) return Promise.resolve(null);
    const settings = { variant: 'standard', title: 'Conferma azione', message: '', warning: '', cancelText: 'Annulla', confirmText: 'Conferma', input: null, ...options };
    const previousFocus = document.activeElement;
    const overlay = createElement('div', `confirm-modal-overlay confirm-modal-${settings.variant}`);
    const dialog = createElement('section', 'confirm-modal');
    const title = createElement('h2', 'confirm-modal-title', settings.title);
    const message = createElement('p', 'confirm-modal-message', settings.message);
    const actions = createElement('div', 'confirm-modal-actions');
    const cancelButton = createElement('button', 'confirm-modal-cancel', settings.cancelText);
    const confirmButton = createElement('button', `confirm-modal-confirm${settings.variant === 'danger' ? ' is-danger' : ''}`, settings.confirmText);
    const closeButton = createElement('button', 'confirm-modal-close', '×');
    const backgroundElements = [...document.body.children].map((element) => ({ element, inert: element.inert, ariaHidden: element.getAttribute('aria-hidden') }));
    let input;
    activeModal = overlay;
    dialog.setAttribute('role', 'dialog'); dialog.setAttribute('aria-modal', 'true'); dialog.setAttribute('aria-labelledby', 'confirm-modal-title'); title.id = 'confirm-modal-title';
    closeButton.type = cancelButton.type = confirmButton.type = 'button'; closeButton.setAttribute('aria-label', 'Chiudi finestra');
    dialog.append(closeButton, title, message);
    if (settings.warning) dialog.appendChild(createElement('p', 'confirm-modal-warning', settings.warning));
    if (settings.input) {
      const field = createElement('div', 'confirm-modal-field'); const label = createElement('label', '', settings.input.label);
      input = document.createElement('input'); input.id = 'confirm-modal-input'; input.type = settings.input.type || 'text'; input.value = settings.input.value || ''; input.required = Boolean(settings.input.required); label.htmlFor = input.id;
      field.append(label, input); dialog.appendChild(field);
    }
    actions.append(cancelButton, confirmButton); dialog.appendChild(actions); overlay.appendChild(dialog);
    return new Promise((resolve) => {
      function finish(result) {
        if (activeModal !== overlay) return;
        document.removeEventListener('keydown', onKeyDown); overlay.remove(); document.body.classList.remove('confirm-modal-open');
        backgroundElements.forEach(({ element, inert, ariaHidden }) => { element.inert = inert; if (ariaHidden === null) element.removeAttribute('aria-hidden'); else element.setAttribute('aria-hidden', ariaHidden); });
        activeModal = null; if (previousFocus && typeof previousFocus.focus === 'function') previousFocus.focus(); resolve(result);
      }
      function submit() { if (input && !input.reportValidity()) return; confirmButton.disabled = cancelButton.disabled = closeButton.disabled = true; finish(input ? input.value : true); }
      function onKeyDown(event) {
        if (event.key === 'Escape') { event.preventDefault(); finish(null); return; }
        if (event.key === 'Enter' && input && document.activeElement === input) { event.preventDefault(); submit(); return; }
        if (event.key !== 'Tab') return;
        const focusable = [closeButton, input, cancelButton, confirmButton].filter(Boolean); const index = focusable.indexOf(document.activeElement);
        if (event.shiftKey && (index <= 0 || index === -1)) { event.preventDefault(); focusable.at(-1).focus(); }
        else if (!event.shiftKey && (index === focusable.length - 1 || index === -1)) { event.preventDefault(); closeButton.focus(); }
      }
      closeButton.addEventListener('click', () => finish(null)); cancelButton.addEventListener('click', () => finish(null)); confirmButton.addEventListener('click', submit);
      overlay.addEventListener('click', (event) => { if (event.target === overlay) finish(null); }); document.addEventListener('keydown', onKeyDown);
      backgroundElements.forEach(({ element }) => { element.inert = true; element.setAttribute('aria-hidden', 'true'); }); document.body.classList.add('confirm-modal-open'); document.body.appendChild(overlay); (input || cancelButton).focus();
    });
  }
  function confirm(options) { return openModal(options).then((result) => result === true); }
  function prompt(options) { return openModal({ ...options, input: options.input || {} }); }
  window.FamilAreaConfirm = { confirm, prompt };
}());
