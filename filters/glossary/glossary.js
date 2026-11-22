// Glossary popups: shows a term's definition when a glossary term is hovered
// with a mouse, tapped on a touch screen, or focused with the keyboard
// (Tab to the term; Enter or Space pins it open; Escape closes it).
//
// The terms are <span class="glossary-term"> elements added by glossary.lua.
// Each one's aria-describedby points at its definition in the hidden
// .glossary-defs block, so screen readers read the definition on focus
// without needing this popup.
(function () {
  "use strict";

  const TERM = ".glossary-term";
  const GAP = 8;        // px between the term and the popup
  const MARGIN = 8;     // px kept clear of the window edges
  const SHOW_DELAY = 120;
  const HIDE_DELAY = 200;

  let pop = null;
  let current = null;   // the term the popup belongs to
  let pinned = false;   // opened by a click, tap, or key: stays until dismissed
  let showTimer = null;
  let hideTimer = null;
  let lastPointer = "mouse";
  let openAtPointerDown = false;

  function popup() {
    if (pop) return pop;
    pop = document.createElement("div");
    pop.className = "glossary-popover";
    pop.id = "glossary-popover";
    pop.setAttribute("role", "tooltip");
    pop.hidden = true;
    pop.innerHTML =
      '<div class="glossary-popover-term"></div>' +
      '<div class="glossary-popover-def"></div>';
    document.body.appendChild(pop);
    // Let the pointer move onto the popup without it closing.
    pop.addEventListener("pointerenter", () => clearTimeout(hideTimer));
    pop.addEventListener("pointerleave", (e) => {
      if (e.pointerType === "mouse" && !pinned) scheduleHide();
    });
    return pop;
  }

  function isOpen(term) {
    return pop && !pop.hidden && (!term || current === term);
  }

  function place() {
    if (!isOpen()) return;
    const rects = current.getClientRects();
    if (!rects.length) return hide();
    // A term can wrap onto two lines; anchor to its first line.
    const r = rects[0];
    const w = pop.offsetWidth;
    const h = pop.offsetHeight;
    const vw = document.documentElement.clientWidth;
    // The visible height: on phones, window.innerHeight can include the area
    // behind the browser's toolbars.
    const vh = Math.min(
      document.documentElement.clientHeight || Infinity,
      window.visualViewport ? window.visualViewport.height : Infinity,
      window.innerHeight
    );

    let top = r.bottom + GAP;
    let above = false;
    if (top + h > vh - MARGIN && r.top - GAP - h >= MARGIN) {
      top = r.top - GAP - h;
      above = true;
    }
    let left = r.left + r.width / 2 - w / 2;
    left = Math.max(MARGIN, Math.min(left, vw - w - MARGIN));

    pop.style.top = Math.round(top) + "px";
    pop.style.left = Math.round(left) + "px";
    pop.classList.toggle("is-above", above);
  }

  function show(term, pin) {
    clearTimeout(showTimer);
    clearTimeout(hideTimer);
    const def = document.getElementById(term.getAttribute("aria-describedby"));
    if (!def) return;
    const p = popup();
    // Keep a pinned popup pinned when it is hovered or focused again.
    pinned = (pinned && isOpen(term)) || !!pin;
    if (current && current !== term) current.removeAttribute("data-open");
    current = term;
    p.querySelector(".glossary-popover-term").textContent = term.dataset.term || term.textContent;
    p.querySelector(".glossary-popover-def").innerHTML = def.innerHTML;
    p.hidden = false;
    term.setAttribute("data-open", "");
    place();
  }

  function hide() {
    clearTimeout(showTimer);
    clearTimeout(hideTimer);
    if (pop) pop.hidden = true;
    if (current) current.removeAttribute("data-open");
    current = null;
    pinned = false;
  }

  function scheduleHide() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(hide, HIDE_DELAY);
  }

  // Mouse hover
  document.addEventListener("pointerover", (e) => {
    if (e.pointerType !== "mouse") return;
    const term = e.target.closest && e.target.closest(TERM);
    if (!term) return;
    clearTimeout(hideTimer);
    if (pinned && current !== term) return; // don't steal a pinned popup
    if (isOpen(term)) return;
    clearTimeout(showTimer);
    showTimer = setTimeout(() => show(term, false), SHOW_DELAY);
  });

  document.addEventListener("pointerout", (e) => {
    if (e.pointerType !== "mouse") return;
    const term = e.target.closest && e.target.closest(TERM);
    if (!term || term.contains(e.relatedTarget)) return;
    clearTimeout(showTimer);
    if (!pinned && current === term) scheduleHide();
  });

  // Click and tap
  document.addEventListener("pointerdown", (e) => {
    lastPointer = e.pointerType || "mouse";
    const term = e.target.closest && e.target.closest(TERM);
    openAtPointerDown = !!term && isOpen(term) && (pinned || lastPointer !== "mouse");
    if (!term && pop && !pop.contains(e.target)) hide();
  });

  document.addEventListener("click", (e) => {
    const term = e.target.closest && e.target.closest(TERM);
    if (!term) return;
    // A second tap or click on an open, pinned term closes it.
    if (openAtPointerDown) hide();
    else show(term, true);
    openAtPointerDown = false;
  });

  // Keyboard
  document.addEventListener("focusin", (e) => {
    const term = e.target.closest && e.target.closest(TERM);
    if (term && !isOpen(term)) show(term, false);
  });

  document.addEventListener("focusout", (e) => {
    const term = e.target.closest && e.target.closest(TERM);
    if (term && current === term) hide();
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && isOpen()) {
      hide();
      return;
    }
    const term = e.target.closest && e.target.closest(TERM);
    if (!term) return;
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault(); // stop Space from scrolling the page
      if (isOpen(term) && pinned) hide();
      else show(term, true);
    }
  });

  // Keep the popup next to its term.
  let frame = 0;
  function reposition() {
    if (frame || !isOpen()) return;
    frame = requestAnimationFrame(() => { frame = 0; place(); });
  }
  window.addEventListener("scroll", reposition, { passive: true, capture: true });
  window.addEventListener("resize", reposition);
})();
