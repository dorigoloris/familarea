(function attachDateUtils(global) {
  function formatDateDisplay(value) {
    if (typeof value !== 'string') return '';
    const match = value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (!match) return '';

    const [, year, month, day] = match;
    const date = new Date(Number(year), Number(month) - 1, Number(day));
    if (date.getFullYear() !== Number(year)
      || date.getMonth() !== Number(month) - 1
      || date.getDate() !== Number(day)) return '';

    return `${day}-${month}-${year}`;
  }

  global.FamilAreaDateUtils = { formatDateDisplay };
}(window));
