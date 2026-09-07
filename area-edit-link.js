(async function () {
  const link = document.getElementById('edit-area-link');
  const areaId = new URLSearchParams(window.location.search).get('area_id');
  if (!link || !areaId) return;
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) return;
  const { data: profile } = await supabaseClient.from('profiles').select('id').eq('user_id', sessionData.session.user.id).single();
  const { data: memberships, error } = await supabaseClient.from('area_memberships').select('profile_id,role').eq('area_id', areaId);
  if (!error && memberships?.some((membership) => membership.profile_id === profile?.id && membership.role === 'admin')) {
    link.href = `modifica-area.html?area_id=${encodeURIComponent(areaId)}`;
    link.hidden = false;
  }
}());
