const deadlineManagementClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

async function initialiseDeadlineManagement() {
  const { data: session } = await deadlineManagementClient.auth.getSession();
  if (!session?.session) window.location.assign('login.html');
}

void initialiseDeadlineManagement();
