// Custom file picker. The native <input type="file"> button doesn't
// match the rest of the app's mono/dark aesthetic and varies wildly
// across OSes. Wrap it in a styled label that surfaces the selected
// filename in our typography, while leaving the actual <input>
// untouched so form submission and validation behave normally.
(function () {
  "use strict";

  const PLACEHOLDER = "no file chosen";

  function init(root) {
    const input = root.querySelector("[data-filepicker-input]");
    const nameEl = root.querySelector("[data-filepicker-name]");
    if (!input || !nameEl) return;

    function paint() {
      const file = input.files && input.files[0];
      if (file) {
        nameEl.textContent = file.name;
        root.classList.add("filepicker--has-file");
      } else {
        nameEl.textContent = PLACEHOLDER;
        root.classList.remove("filepicker--has-file");
      }
    }

    input.addEventListener("change", paint);
    paint();
  }

  document.querySelectorAll("[data-filepicker]").forEach(init);
})();
