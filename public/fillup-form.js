// Swaps the inline unit labels on the manual-fillup form when the
// user toggles between metric and US customary. Field values pass
// through untouched — the row stores what the operator typed,
// tagged with the toggle's unit_system + currency.
(() => {
  const form = document.querySelector("[data-fillup-form]");
  if (!form) return;

  const LABELS = {
    volume:           { metric: "L",       us_customary: "gal" },
    distance:         { metric: "km",      us_customary: "mi" },
    economy:          { metric: "L/100km", us_customary: "MPG" },
    price_per_volume: { metric: "/L",      us_customary: "/gal" },
  };

  function applyUnits() {
    const selected = form.querySelector("[data-fillup-units]:checked");
    if (!selected) return;
    const system = selected.value;
    form.querySelectorAll("[data-fillup-label]").forEach((el) => {
      const kind = el.dataset.fillupLabel;
      const mapping = LABELS[kind];
      if (!mapping) return;
      el.textContent = mapping[system] || mapping.metric;
    });
  }

  form.querySelectorAll("[data-fillup-units]").forEach((radio) => {
    radio.addEventListener("change", applyUnits);
  });
  applyUnits();
})();
