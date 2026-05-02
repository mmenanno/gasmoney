(function () {
  "use strict";

  // Custom confirm modal driven by data-confirm attributes on <form>
  // elements. Replaces the native window.confirm() call so destructive
  // actions get a dialog that matches the rest of the dark-mode chrome.
  //
  // Markup contract:
  //   <form ... data-confirm="Body text (HTML allowed)"
  //              data-confirm-action="Confirm button label"
  //              data-confirm-tone="danger|default">
  //
  // Tone "danger" paints the confirm button with --alert. Default and
  // unset tones use --accent (the same teal as the primary buttons).

  function buildModal() {
    const overlay = document.createElement("div");
    overlay.className = "modal-overlay";
    overlay.setAttribute("hidden", "");
    overlay.innerHTML =
      '<div class="modal" role="dialog" aria-modal="true" aria-labelledby="modal-title">' +
        '<h2 class="modal__title" id="modal-title">Confirm</h2>' +
        '<div class="modal__body"></div>' +
        '<div class="modal__actions">' +
          '<button type="button" class="btn btn--ghost modal__cancel">Cancel</button>' +
          '<button type="button" class="btn btn--primary modal__confirm">Confirm</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(overlay);
    return overlay;
  }

  let overlay, modal, body, confirmBtn, cancelBtn;
  let pendingForm = null;
  let lastFocused = null;

  function ensureMounted() {
    if (overlay) return;
    overlay = buildModal();
    modal = overlay.querySelector(".modal");
    body = overlay.querySelector(".modal__body");
    confirmBtn = overlay.querySelector(".modal__confirm");
    cancelBtn = overlay.querySelector(".modal__cancel");

    overlay.addEventListener("click", function (e) {
      if (e.target === overlay) close();
    });
    cancelBtn.addEventListener("click", close);
    confirmBtn.addEventListener("click", function () {
      const form = pendingForm;
      close();
      if (form) {
        // Bypass our own delegated submit handler so we don't loop back
        // into the modal — submit() programmatically and the form goes
        // straight to the server.
        form.dataset.confirmed = "1";
        form.submit();
      }
    });
    document.addEventListener("keydown", function (e) {
      if (overlay.hidden) return;
      if (e.key === "Escape") {
        e.preventDefault();
        close();
      } else if (e.key === "Tab") {
        // Trap focus between the two buttons.
        const focusables = [cancelBtn, confirmBtn];
        const idx = focusables.indexOf(document.activeElement);
        e.preventDefault();
        const next = e.shiftKey
          ? focusables[(idx - 1 + focusables.length) % focusables.length]
          : focusables[(idx + 1) % focusables.length];
        next.focus();
      }
    });
  }

  function open(form) {
    ensureMounted();
    pendingForm = form;
    body.innerHTML = form.dataset.confirm || "Are you sure?";
    confirmBtn.textContent = form.dataset.confirmAction || "Confirm";

    const tone = form.dataset.confirmTone || "default";
    confirmBtn.classList.toggle("btn--danger", tone === "danger");
    confirmBtn.classList.toggle("btn--primary", tone !== "danger");

    lastFocused = document.activeElement;
    overlay.hidden = false;
    document.body.classList.add("modal-open");
    // Default focus on Cancel — destructive actions shouldn't be one
    // accidental Enter away from firing.
    setTimeout(function () { cancelBtn.focus(); }, 0);
  }

  function close() {
    if (!overlay || overlay.hidden) return;
    overlay.hidden = true;
    document.body.classList.remove("modal-open");
    pendingForm = null;
    if (lastFocused && typeof lastFocused.focus === "function") {
      lastFocused.focus();
    }
  }

  // Capture form submissions at the document level so dynamically-added
  // forms (currently none, but keeps the contract simple) work too.
  document.addEventListener("submit", function (e) {
    const form = e.target;
    if (!form.matches || !form.matches("form[data-confirm]")) return;
    if (form.dataset.confirmed === "1") {
      // Cleanup so a follow-up submission still triggers the modal.
      delete form.dataset.confirmed;
      return;
    }
    e.preventDefault();
    open(form);
  });
})();
