(function () {
  "use strict";

  function init(root) {
    const button = root.querySelector(".select__button");
    const list = root.querySelector(".select__list");
    const valueEl = root.querySelector(".select__value");
    const hidden = root.querySelector('input[type="hidden"]');
    const options = Array.from(root.querySelectorAll(".select__option"));
    if (!button || !list || !valueEl || options.length === 0) return;

    let highlightedIndex = options.findIndex(function (o) {
      return o.classList.contains("select__option--selected");
    });

    function open() {
      list.hidden = false;
      button.setAttribute("aria-expanded", "true");
      root.classList.add("select--open");
      if (highlightedIndex < 0) highlightedIndex = 0;
      paintHighlight();
      ensureVisible(options[highlightedIndex]);
    }
    function close() {
      list.hidden = true;
      button.setAttribute("aria-expanded", "false");
      root.classList.remove("select--open");
    }
    function toggle() {
      list.hidden ? open() : close();
    }
    function paintHighlight() {
      options.forEach(function (o, i) {
        o.classList.toggle("select__option--highlighted", i === highlightedIndex);
      });
    }
    function ensureVisible(el) {
      if (!el) return;
      el.scrollIntoView({ block: "nearest" });
    }
    function select(opt) {
      if (!opt) return;
      const href = opt.dataset.href;
      if (href) {
        window.location.href = href;
        return;
      }
      const value = opt.dataset.value || "";
      const text = opt.textContent.trim();
      if (hidden) hidden.value = value;
      valueEl.textContent = text;
      options.forEach(function (o) {
        o.classList.toggle("select__option--selected", o === opt);
      });
      close();
      root.dispatchEvent(new CustomEvent("select:change", { bubbles: true, detail: { value: value, text: text } }));
    }

    button.addEventListener("click", function (e) {
      e.preventDefault();
      toggle();
    });
    button.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        if (list.hidden) open();
      } else if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        if (list.hidden) {
          open();
        } else {
          select(options[highlightedIndex]);
        }
      } else if (e.key === "Escape") {
        close();
      }
    });
    root.addEventListener("keydown", function (e) {
      if (list.hidden) return;
      if (e.key === "ArrowDown") {
        e.preventDefault();
        highlightedIndex = Math.min(options.length - 1, highlightedIndex + 1);
        paintHighlight();
        ensureVisible(options[highlightedIndex]);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        highlightedIndex = Math.max(0, highlightedIndex - 1);
        paintHighlight();
        ensureVisible(options[highlightedIndex]);
      } else if (e.key === "Home") {
        e.preventDefault();
        highlightedIndex = 0;
        paintHighlight();
        ensureVisible(options[highlightedIndex]);
      } else if (e.key === "End") {
        e.preventDefault();
        highlightedIndex = options.length - 1;
        paintHighlight();
        ensureVisible(options[highlightedIndex]);
      }
    });
    list.addEventListener("click", function (e) {
      const opt = e.target.closest(".select__option");
      if (opt) select(opt);
    });
    list.addEventListener("mousemove", function (e) {
      const opt = e.target.closest(".select__option");
      if (!opt) return;
      const idx = options.indexOf(opt);
      if (idx >= 0 && idx !== highlightedIndex) {
        highlightedIndex = idx;
        paintHighlight();
      }
    });
    document.addEventListener("click", function (e) {
      if (!root.contains(e.target)) close();
    });
  }

  function initAll() {
    document.querySelectorAll("[data-select]").forEach(init);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initAll);
  } else {
    initAll();
  }
})();
