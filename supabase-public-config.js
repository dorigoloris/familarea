const SUPABASE_URL = 'https://dqdmevxtdrefiqggtirh.supabase.co';
const SUPABASE_KEY = 'sb_publishable_S11fyDqQ_RLWQj_jUMiPwQ_Usfj328M';

// La site key Turnstile è pubblica. Lasciare la protezione disattivata finché
// la secret key non è configurata anche in Supabase Auth.
window.FamilAreaCaptchaConfig = Object.freeze({
  enabled: false,
  provider: 'turnstile',
  siteKey: ''
});
