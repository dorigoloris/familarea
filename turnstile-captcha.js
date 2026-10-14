(() => {
  const turnstileScriptUrl = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
  let turnstileLoadPromise;

  function config() {
    return window.FamilAreaCaptchaConfig || {};
  }

  function isEnabled() {
    const settings = config();
    return settings.enabled === true && settings.provider === 'turnstile' && typeof settings.siteKey === 'string' && settings.siteKey.trim() !== '';
  }

  function loadTurnstile() {
    if (window.turnstile) return Promise.resolve(window.turnstile);
    if (turnstileLoadPromise) return turnstileLoadPromise;

    turnstileLoadPromise = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = turnstileScriptUrl;
      script.async = true;
      script.defer = true;
      script.onload = () => window.turnstile ? resolve(window.turnstile) : reject(new Error('Turnstile non disponibile.'));
      script.onerror = () => reject(new Error('Impossibile caricare la verifica anti-bot.'));
      document.head.append(script);
    });
    return turnstileLoadPromise;
  }

  function create(container, onStateChange = () => {}) {
    let token = '';
    let widgetId;
    let loading = false;
    const notify = (state) => onStateChange(state);

    if (!container || !isEnabled()) {
      if (container) container.hidden = true;
      return Object.freeze({ enabled: false, getToken: () => '', validate: () => '', reset: () => {} });
    }

    container.hidden = false;
    container.replaceChildren();
    loading = true;
    notify('loading');

    loadTurnstile()
      .then((turnstile) => {
        widgetId = turnstile.render(container, {
          sitekey: config().siteKey.trim(),
          callback(nextToken) {
            token = typeof nextToken === 'string' ? nextToken : '';
            notify(token ? 'verified' : 'error');
          },
          'expired-callback'() {
            token = '';
            notify('expired');
          },
          'error-callback'() {
            token = '';
            notify('error');
          }
        });
        loading = false;
        notify('ready');
      })
      .catch(() => {
        loading = false;
        token = '';
        notify('error');
      });

    return Object.freeze({
      enabled: true,
      getToken: () => token,
      validate: () => loading ? 'La verifica anti-bot è in caricamento.' : (token ? '' : 'Completa la verifica anti-bot prima di continuare.'),
      reset: () => {
        token = '';
        if (widgetId !== undefined && window.turnstile) window.turnstile.reset(widgetId);
      }
    });
  }

  window.FamilAreaCaptcha = Object.freeze({ create, isEnabled });
})();
