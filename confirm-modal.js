(function () {
  let activeModal = null;

  function createElement(tagName, className, text) {
    const element = document.createElement(tagName);
    if (className) element.className = className;
    if (text) element.textContent = text;
    return element;
  }

  function confirm(options) {
    if (activeModal) return Promise.resolve(false);

    const settings = {
      variant: 'standard',
      title: 'Conferma azione',
      message: '',
      warning: '',
      cancelText: 'Annulla',
      confirmText: 'Conferma',
      ...options
    };
    const previousFocus = document.activeElement;
    const overlay = createElement('div', `confirm-modal-overlay confirm-modal-${settings.variant}`);
    const dialog = createElement('section', 'confirm-modal');
    const title = createElement('h2', 'confirm-modal-title', settings.title);
    const message = createElement('p', 'confirm-modal-message', settings.message);
    const actions = createElement('div', 'confirm-modal-actions');
    const cancelButton = createElement('button', 'confirm-modal-cancel', settings.cancelText);
    const confirmButton = createElement('button', `confirm-modal-confirm${settings.variant === 'danger' ? ' is-danger' : ''}`, settings.confirmText);
    const closeButton = createElement('button', 'confirm-modal-close', '×');
    const backgroundElements = [...document.body.children].map((element) => ({
      element,
      inert: element.inert,
      ariaHidden: element.getAttribute('aria-hidden')
    }));

    activeModal = overlay;
    overlay.tabIndex = -1;
    overlay.setAttribute('role', 'presentation');
    dialog.setAttribute('role', 'dialog');
    dialog.setAttribute('aria-modal', 'true');
    dialog.setAttribute('aria-labelledby', 'confirm-modal-title');
    title.id = 'confirm-modal-title';
    closeButton.type = 'button';
    closeButton.setAttribute('aria-label', 'Chiudi conferma');
    cancelButton.type = 'button';
    confirmButton.type = 'button';

    if (settings.variant === 'danger') {
      const indicator = createElement('span', 'confirm-modal-danger-icon', '!');
      indicator.setAttribute('aria-hidden', 'true');
      dialog.appendChild(indicator);
    }

    dialog.append(closeButton, title, message);
    if (settings.warning) {
      const warning = createElement('p', 'confirm-modal-warning', settings.warning);
      dialog.appendChild(warning);
    }
    actions.append(cancelButton, confirmButton);
    dialog.appendChild(actions);
    overlay.appendChild(dialog);

    return new Promise((resolve) => {
      function finish(result) {
        if (activeModal !== overlay) return;
        document.removeEventListener('keydown', onKeyDown);
        overlay.remove();
        document.body.classList.remove('confirm-modal-open');
        backgroundElements.forEach(({ element, inert, ariaHidden }) => {
          element.inert = inert;
          if (ariaHidden === null) element.removeAttribute('aria-hidden');
          else element.setAttribute('aria-hidden', ariaHidden);
        });
        activeModal = null;
        if (previousFocus && typeof previousFocus.focus === 'function') previousFocus.focus();
        resolve(result);
      }

      function onKeyDown(event) {
        if (event.key === 'Escape') {
          event.preventDefault();
          finish(false);
          return;
        }
        if (event.key !== 'Tab') return;
        const focusable = [closeButton, cancelButton, confirmButton];
        const index = focusable.indexOf(document.activeElement);
        if (event.shiftKey && (index <= 0 || index === -1)) {
          event.preventDefault();
          confirmButton.focus();
        } else if (!event.shiftKey && (index === focusable.length - 1 || index === -1)) {
          event.preventDefault();
          closeButton.focus();
        }
      }

      closeButton.addEventListener('click', () => finish(false));
      cancelButton.addEventListener('click', () => finish(false));
      confirmButton.addEventListener('click', () => {
        confirmButton.disabled = true;
        cancelButton.disabled = true;
        closeButton.disabled = true;
        finish(true);
      });
      overlay.addEventListener('click', (event) => {
        if (event.target === overlay) finish(false);
      });
      document.addEventListener('keydown', onKeyDown);
      backgroundElements.forEach(({ element }) => {
        element.inert = true;
        element.setAttribute('aria-hidden', 'true');
      });
      document.body.classList.add('confirm-modal-open');
      document.body.appendChild(overlay);
      cancelButton.focus();
    });
  }

  window.FamilAreaConfirm = { confirm };
}());
