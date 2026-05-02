(function () {
  "use strict";

  const toggle = document.querySelector(".nav-toggle");
  const panel = document.querySelector(".nav");
  if (!toggle || !panel) return;

  function open() {
    document.body.classList.add("nav-open");
    toggle.setAttribute("aria-expanded", "true");
    // Defer wiring the outside-click handler so the same click that
    // opens the panel doesn't immediately close it.
    setTimeout(function () {
      document.addEventListener("click", onOutsideClick, true);
    }, 0);
  }

  function close() {
    document.body.classList.remove("nav-open");
    toggle.setAttribute("aria-expanded", "false");
    document.removeEventListener("click", onOutsideClick, true);
  }

  function onOutsideClick(e) {
    if (panel.contains(e.target) || toggle.contains(e.target)) return;
    close();
  }

  toggle.addEventListener("click", function (e) {
    e.stopPropagation();
    document.body.classList.contains("nav-open") ? close() : open();
  });

  // Clicking a nav link closes the panel — without this it would stay
  // open during the navigation, then reopen looking jarring on the new
  // page since CSS doesn't preserve state across loads.
  panel.addEventListener("click", function (e) {
    if (e.target.matches("a")) close();
  });

  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && document.body.classList.contains("nav-open")) {
      close();
    }
  });

  // The CSS shows the panel as part of the topbar at desktop widths.
  // If the user resizes from mobile (panel open) up to desktop, the
  // open class would leave the body in a weird state — normalize.
  window.addEventListener("resize", function () {
    if (window.matchMedia("(min-width: 721px)").matches) close();
  });
})();
