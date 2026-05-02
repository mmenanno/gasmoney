// "Change" button on each linked Vehicle linking row swaps the
// locked-in summary for the editable dropdown form. Server-rendered
// state starts collapsed (summary visible, form hidden) when a row
// is already linked, so this script's only job is the toggle.
(function () {
  "use strict";

  document.addEventListener("click", function (e) {
    const trigger = e.target.closest("[data-link-edit]");
    if (!trigger) return;

    const cell = trigger.closest("[data-link-cell]");
    if (!cell) return;

    const summary = cell.querySelector("[data-link-summary]");
    const form = cell.querySelector("[data-link-form]");
    if (!summary || !form) return;

    summary.hidden = true;
    form.hidden = false;
    trigger.hidden = true;

    // Move focus into the dropdown so keyboard users land where they
    // expect after invoking change.
    const button = form.querySelector(".select__button");
    button && button.focus();
  });
})();
