(function () {
  const message = document.getElementById('redirect-message');
  const areaId = new URLSearchParams(window.location.search).get('area_id');

  if (!areaId) {
    message.textContent = 'Area non specificata.';
    return;
  }

  window.location.replace(`inviti-area.html?area_id=${encodeURIComponent(areaId)}`);
}());
