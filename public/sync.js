(function () {
  "use strict";

  // Polls /sync/runs/<id>.json for any run flagged data-running="1" and
  // updates its counts + log entries in place. Stops polling once the
  // run reaches a terminal state, then triggers a soft full-page reload
  // so the new run also appears in the activity feed history.

  const POLL_INTERVAL_MS = 2_000;

  function start() {
    const runningEls = Array.from(document.querySelectorAll('[data-running="1"]'));
    if (runningEls.length === 0) return;
    runningEls.forEach(pollRun);
  }

  function pollRun(el) {
    const id = el.dataset.runId;
    if (!id) return;

    const tick = () => {
      fetch(`/sync/runs/${id}.json`, { headers: { Accept: "application/json" } })
        .then(r => r.json())
        .then(data => {
          updateCounts(el, data);
          updateLog(el, data);
          if (data.status !== "running") {
            // Reload so the run gets re-rendered with its terminal status
            // (and the run-list left-rail color settles into place).
            window.location.reload();
            return;
          }
          setTimeout(tick, POLL_INTERVAL_MS);
        })
        .catch(() => setTimeout(tick, POLL_INTERVAL_MS));
    };
    setTimeout(tick, POLL_INTERVAL_MS);
  }

  function updateCounts(el, data) {
    el.querySelectorAll("[data-count]").forEach(node => {
      const key = node.dataset.count;
      if (data[key] != null) node.textContent = String(data[key]);
    });
  }

  function updateLog(el, data) {
    const container = el.querySelector("[data-log-entries]");
    const counter = el.querySelector("[data-log-count]");
    if (!container || !data.log) return;

    const existing = container.querySelectorAll(".log-entry").length;
    if (data.log.length !== existing) {
      // Append only the new entries — the order is stable.
      for (let i = existing; i < data.log.length; i++) {
        container.appendChild(renderLogEntry(data.log[i]));
      }
      if (counter) counter.textContent = String(data.log.length);
    }

    // Update the "now happening" line at the top of the run card so
    // backfill progress is visible without expanding the log.
    const currentMsg = el.querySelector("[data-run-current-msg]");
    if (currentMsg && data.log.length > 0) {
      const last = data.log[data.log.length - 1];
      if (last && last.message) currentMsg.textContent = last.message;
    }
  }

  function renderLogEntry(entry) {
    const li = document.createElement("li");
    li.className = `log-entry log-entry--${entry.level}`;

    const time = document.createElement("span");
    time.className = "log-entry__time";
    time.textContent = (entry.at || "").slice(11, 19);

    const msg = document.createElement("span");
    msg.className = "log-entry__msg";
    msg.textContent = entry.message;

    li.appendChild(time);
    li.appendChild(msg);

    if (entry.detail) {
      const pre = document.createElement("pre");
      pre.className = "log-entry__detail";
      pre.textContent = JSON.stringify(entry.detail, null, 2);
      li.appendChild(pre);
    }
    return li;
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
