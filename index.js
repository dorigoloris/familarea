const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const authActions = document.getElementById('public-auth-actions');
const dashboardAction = document.getElementById('public-dashboard-action');

(async () => {
  const { data, error } = await supabaseClient.auth.getSession();
  if (error || !data.session) return;
  authActions.hidden = true;
  dashboardAction.hidden = false;
})().catch(() => {});
