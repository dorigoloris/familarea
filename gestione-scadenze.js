const deadlineManagementClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

async function initialiseDeadlineManagement() {
  const { data: session } = await deadlineManagementClient.auth.getSession();
  if (!session?.session) {
    window.location.assign('login.html');
    return false;
  }
  const account = await window.FamilAreaRequirePersonal?.();
  if (!account) return false;
  document.querySelector('[data-deadline-management-content]')?.removeAttribute('hidden');
  return true;
}

window.FamilAreaDeadlineManagementReady = initialiseDeadlineManagement();
