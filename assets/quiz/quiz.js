/*
  GEOG 215 chapter quizzes: one question at a time, then the ones you missed
  again until every one is right.

  A quiz page holds  <div class="sds-quiz" data-bank="../quizzes/<chapter>.json">
  and loads this script and quiz.css. The bank (see quizzes/README.md) lists
  20-30 questions; each session asks `perSession` of them (default 10) at
  random, with at least `minR` R questions (default 3) when the bank has them.

  Results are saved through window.sdsProgress, which the geog215.org sign-in
  gate (assets/auth-gate.html) provides. On daveparr.com there is no gate, so
  the quiz works the same but nothing is saved.

  "Write R code" questions run real R in the browser with webR, loaded only
  when a session includes one.

  Right and wrong answers play a short sound (Web Audio, no files), which
  students can turn off with the speaker button by the progress bar.
*/
(function () {
  "use strict";

  // Same webR version as the book's code cells (_extensions/coatless/webr).
  const WEBR_URL = "https://webr.r-wasm.org/v0.6.0/webr.mjs";
  const R_TYPES = ["fill", "order", "code"];

  // ---- Small helpers ---------------------------------------------------------
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

  // Question text: `code`, **bold** and *italic*, everything else escaped.
  // Bold and italic apply only outside code, so `7 * 24` stays as written.
  function md(text) {
    return String(text ?? "").split(/(`[^`]+`)/).map((part, i) => {
      if (i % 2) return "<code>" + esc(part.slice(1, -1)) + "</code>";
      return esc(part)
        .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
        .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>");
    }).join("");
  }

  function shuffle(list) {
    const a = list.slice();
    for (let i = a.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [a[i], a[j]] = [a[j], a[i]];
    }
    return a;
  }

  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    const b = crypto.getRandomValues(new Uint8Array(16));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  }

  function record(fn, args) {
    try {
      if (window.sdsProgress && window.sdsProgress.record) window.sdsProgress.record(fn, args);
    } catch (_) { /* saving never breaks the quiz */ }
  }

  const el = (tag, attrs, html) => {
    const n = document.createElement(tag);
    if (attrs) for (const [k, v] of Object.entries(attrs)) {
      if (k === "class") n.className = v; else n.setAttribute(k, v);
    }
    if (html != null) n.innerHTML = html;
    return n;
  };

  const reduceMotion = () =>
    window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---- Cartoon Dave, who cheers on right answers ----------------------------
  // Inline so quiz.css can animate it (pop in, bob, blink) and so it needs no
  // extra file path on quiz pages at different depths.
  // The face changes with the mood: raised brows and a big smile when right,
  // worried brows and a frown when wrong.
  const COACH_FACES = {
    happy: {
      brows: "M43 49.5 Q49 46 54 49 M66 49 Q71 46 77 49.5",
      mouth: `<path d="M47 75.5 Q60 92 73 75.5 Q60 79 47 75.5 Z" fill="#7a2e2e"/>
    <path d="M48.5 76.3 Q60 79.6 71.5 76.3 L70.6 78.6 Q60 81.6 49.4 78.6 Z" fill="#fff"/>`,
    },
    sad: {
      brows: "M43 50.5 Q48.5 49.5 54 46 M66 46 Q71.5 49.5 77 50.5",
      mouth: `<path d="M50.5 82.5 Q60 75.5 69.5 82.5 Q60 79 50.5 82.5 Z" fill="#7a2e2e" stroke="#7a2e2e" stroke-width="1.6" stroke-linejoin="round"/>`,
    },
  };
  const coachSvg = (mood) => { const f = COACH_FACES[mood]; return `<svg class="sds-q-coach-svg" viewBox="0 0 120 130" aria-hidden="true" focusable="false">
    <path d="M8 130 C10 106 30 97 60 97 C90 97 110 106 112 130 Z" fill="#b19d86"/>
    <path d="M8 130 C10 108 22 100 36 97.5 L45 113 L38 130 Z" fill="#4a5466"/>
    <path d="M112 130 C110 108 98 100 84 97.5 L75 113 L82 130 Z" fill="#4a5466"/>
    <path d="M44 98 Q60 108 76 98" fill="none" stroke="#4a5466" stroke-width="3.5" stroke-linecap="round"/>
    <g transform="translate(64 104) rotate(14)"><path d="M0 0 L0 6" stroke="#1e2228" stroke-width="1.6"/>
      <rect x="-3.5" y="5" width="7" height="14" rx="3.5" fill="#1e2228"/></g>
    <ellipse cx="33.5" cy="61" rx="5" ry="8" fill="#eab296"/>
    <ellipse cx="86.5" cy="61" rx="5" ry="8" fill="#eab296"/>
    <ellipse cx="60" cy="60" rx="27" ry="32" fill="#f3c4a8"/>
    <path d="M33 44 C31 51 32 57 34.5 61 L38 60 C37 54 37.5 49 39 45 Z" fill="#a8a29a"/>
    <path d="M87 44 C89 51 88 57 85.5 61 L82 60 C83 54 82.5 49 81 45 Z" fill="#a8a29a"/>
    <path d="${f.brows}" fill="none" stroke="#8d857c" stroke-width="2.4" stroke-linecap="round"/>
    <g class="sds-q-coach-eye"><ellipse cx="49" cy="55.5" rx="3.2" ry="3.4" fill="#3b4a5a"/><circle cx="50" cy="54.4" r="1" fill="#fff"/></g>
    <g class="sds-q-coach-eye"><ellipse cx="71" cy="55.5" rx="3.2" ry="3.4" fill="#3b4a5a"/><circle cx="72" cy="54.4" r="1" fill="#fff"/></g>
    <path d="M42 57 Q43.5 59.5 45.5 59 M78 57 Q76.5 59.5 74.5 59" fill="none" stroke="#d99a7e" stroke-width="1" stroke-linecap="round"/>
    <ellipse cx="43" cy="66" rx="6" ry="3.6" fill="#ee9c8b" opacity="0.55"/>
    <ellipse cx="77" cy="66" rx="6" ry="3.6" fill="#ee9c8b" opacity="0.55"/>
    <path d="M57.5 57 C56 63 54.5 66 57 67.5 C58.5 68.5 61.5 68.5 63 67.5 C65.5 66 64 63 62.5 57" fill="#eaa98c"/>
    <path d="M33 60 C32 84 43 100 60 100.5 C77 100 88 84 87 60 C85 70 80 75 74 75.5 C68 72 52 72 46 75.5 C40 75 35 70 33 60 Z" fill="#e6e2da"/>
    <path d="M40 84 q2 4 5 6 M50 92 q3 2 5 2.5 M80 84 q-2 4 -5 6 M70 92 q-3 2 -5 2.5" fill="none" stroke="#c9c3ba" stroke-width="1.1" stroke-linecap="round"/>
    ${f.mouth}
    <path d="M43.5 75 C49 69 55.5 69 60 71.5 C64.5 69 71 69 76.5 75 C70.5 72.5 65 73 60 75 C55 73 49.5 72.5 43.5 75 Z" fill="#a99f94"/>
    <g transform="translate(0 -3.5)">
      <path d="M32 46 C31 23 45 13 61 13 C78 13 91 24 89.5 44 C78 39.5 44 39.5 32 46 Z" fill="#2b303b"/>
      <path d="M61 13 C58 22 58 32 59.5 40.5" fill="none" stroke="#1f232c" stroke-width="1.2"/>
      <circle cx="61" cy="13.5" r="2.2" fill="#1f232c"/>
      <path d="M41 30 c2 -4 4 -4 5 -1 s3 3 5 -1 s3 -4 5 0 s3 3 5 -1 s3 -4 5 0 s3 2 5 -1 s2 -2 3 0" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/>
      <path d="M29.5 46 C40 37.5 80 35 97 45 C99.5 48.5 94 51 88 49 C74 44 47 44.5 35 50 C30.5 51.5 27.5 48.5 29.5 46 Z" fill="#22262f"/>
    </g></svg>`; };

  const CHEERS = ["Good job!", "Way to go!", "Nice work!", "You got it!", "Nailed it!",
    "Great job!", "Well done!", "Spot on!", "Keep it up!", "Excellent!"];
  const CONSOLES = ["Oops! So close.", "Not this time.", "Aw, not quite.",
    "That's OK, you'll get it!", "Shake it off!", "Almost!"];
  const lastLine = { happy: -1, sad: -1 };

  // mood is "happy" or "sad"; text defaults to a random line for that mood,
  // never the same one twice in a row.
  function coach(mood, text) {
    if (text == null) {
      const lines = mood === "sad" ? CONSOLES : CHEERS;
      let i;
      do { i = Math.floor(Math.random() * lines.length); } while (i === lastLine[mood]);
      lastLine[mood] = i;
      text = lines[i];
    }
    return el("div", { class: "sds-q-coach is-" + mood },
      coachSvg(mood) + `<div class="sds-q-bubble">${esc(text)}</div>`);
  }

  // What cartoon Dave says on the end-of-quiz screen.
  const FINISH_CHEERS = {
    perfect: ["Perfect score! Way to go!", "Flawless! I'm impressed!", "Every one right the first time!"],
    great: ["Great work! Keep it up!", "Way to go! You've got this!", "Nice job sticking with it!"],
    done: ["You stuck with it. Good job!", "Practice pays off. Way to go!", "Try another set to keep improving!"],
  };

  // ---- Sounds -------------------------------------------------------------------
  // A happy chime on a right answer and a buzzer on a wrong one, made with the
  // Web Audio API (no sound files to load). Students can turn sound off with
  // the speaker button next to the progress bar; the choice is remembered in
  // this browser.
  const SOUND_KEY = "sds-quiz-sound";
  let soundOn = true;
  try { soundOn = localStorage.getItem(SOUND_KEY) !== "off"; } catch (_) { /* default on */ }
  function setSound(on) {
    soundOn = on;
    try { localStorage.setItem(SOUND_KEY, on ? "on" : "off"); } catch (_) { /* not saved */ }
  }

  let audioCtx = null;
  function audio() {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return null;
    if (!audioCtx) audioCtx = new AC();
    if (audioCtx.state === "suspended") audioCtx.resume();
    return audioCtx;
  }

  // One note: a pitch (Hz) that starts `at` seconds from now and fades out.
  function tone(ctx, { freq, at = 0, dur = 0.15, type = "sine", vol = 0.2, slideTo = null }) {
    const t0 = ctx.currentTime + at;
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = type;
    osc.frequency.setValueAtTime(freq, t0);
    if (slideTo) osc.frequency.exponentialRampToValueAtTime(slideTo, t0 + dur);
    gain.gain.setValueAtTime(0.0001, t0);
    gain.gain.exponentialRampToValueAtTime(vol, t0 + 0.01);
    gain.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
    osc.connect(gain).connect(ctx.destination);
    osc.start(t0);
    osc.stop(t0 + dur + 0.02);
  }

  const SOUNDS = {
    // A quick rising arpeggio (C, E, G, high C): bright and cheerful.
    right(ctx) {
      [523.25, 659.25, 783.99, 1046.5].forEach((freq, i) =>
        tone(ctx, { freq, at: i * 0.08, dur: i === 3 ? 0.35 : 0.14, type: "triangle", vol: 0.22 }));
      tone(ctx, { freq: 2093, at: 0.24, dur: 0.3, type: "sine", vol: 0.05 });   // sparkle
    },
    // A low, buzzy "eh-ehh" that drops in pitch, like a game-show buzzer.
    wrong(ctx) {
      tone(ctx, { freq: 155, at: 0, dur: 0.16, type: "sawtooth", vol: 0.16 });
      tone(ctx, { freq: 150, at: 0.19, dur: 0.38, type: "sawtooth", vol: 0.16, slideTo: 110 });
      tone(ctx, { freq: 78, at: 0.19, dur: 0.38, type: "square", vol: 0.06, slideTo: 55 });
    },
    // A short fanfare for finishing the quiz.
    finish(ctx) {
      [[523.25, 0], [659.25, 0.12], [783.99, 0.24], [1046.5, 0.36], [783.99, 0.52], [1046.5, 0.64]]
        .forEach(([freq, at], i) => tone(ctx, { freq, at, dur: i === 5 ? 0.6 : 0.14, type: "triangle", vol: 0.2 }));
    },
  };

  function playSound(name) {
    if (!soundOn) return;
    try {
      const ctx = audio();
      if (ctx) SOUNDS[name](ctx);
    } catch (_) { /* sound never breaks the quiz */ }
  }

  // ---- webR (only for "code" questions) -------------------------------------
  let webRPromise = null;
  function getWebR() {
    if (!webRPromise) {
      webRPromise = import(WEBR_URL).then(async ({ WebR }) => {
        const webR = new WebR();
        await webR.init();
        return webR;
      });
      webRPromise.catch(() => { webRPromise = null; });   // allow a retry
    }
    return webRPromise;
  }

  // Runs the student's code in a fresh environment and, if `check` is given,
  // evaluates that R expression in the same environment. `.sds_code` holds the
  // student's code as text, so a check can look at how they wrote it.
  async function runR(code, check) {
    const webR = await getWebR();
    const shelter = await new webR.Shelter();
    try {
      const env = await new shelter.REnvironment();
      await env.bind(".sds_code", code);
      let output = "", error = null;
      try {
        const res = await shelter.captureR(code, {
          env, withAutoprint: true, captureStreams: true,
          captureConditions: false, captureGraphics: false,
        });
        const lines = [];
        for (const o of res.output) {
          if (o.type !== "stdout" && o.type !== "stderr") continue;
          // webR can report an R error on stderr instead of throwing it.
          if (o.type === "stderr" && error === null && /^Error\b/.test(o.data)) {
            error = o.data.replace(/^Error[^:]*:\s*/, "");
          } else {
            lines.push(o.data);
          }
        }
        output = lines.join("\n");
      } catch (e) {
        error = String(e && e.message || e).replace(/^Error[^:]*:\s*/, "");
      }
      let passed = false;
      if (check && error === null) {
        try {
          passed = await webR.evalRBoolean(
            `isTRUE(tryCatch({\n${check}\n}, error = function(e) FALSE))`, { env });
        } catch (_) { passed = false; }
      }
      return { output, error, passed };
    } finally {
      shelter.purge();
    }
  }

  // ---- Answer checking ----------------------------------------------------------
  // Fill-in answers: ignore spaces, and treat ' and " alike, so "c(1,2)" and
  // "c(1, 2)" both count. Case matters (R cares) unless the question says not.
  function normalizeFill(s, q) {
    let v = String(s || "").trim().replace(/\s+/g, "").replace(/'/g, '"');
    if (q.ignoreCase) v = v.toLowerCase();
    return v;
  }

  function fillIsRight(value, q) {
    if (q.numeric) {
      const n = Number(String(value).replace(/,/g, ""));
      const tol = q.tolerance ?? 1e-9;
      return Number.isFinite(n) && q.answers.some((a) => Math.abs(Number(a) - n) <= tol);
    }
    const v = normalizeFill(value, q);
    return v !== "" && q.answers.some((a) => normalizeFill(a, q) === v);
  }

  function correctAnswerText(q, view) {
    switch (q.type) {
      case "choice": return q.choices[q.answer];
      case "truefalse": return q.answer ? "True" : "False";
      case "fill": return q.answers[0];
      case "order": return q.answer.join(" ");
      case "code": return q.solution || "";
      default: return "";
    }
  }

  // ---- The quiz -------------------------------------------------------------------
  class Quiz {
    constructor(root, bank) {
      this.root = root;
      this.bank = bank;
      this.perSession = Math.min(bank.perSession || 10, bank.questions.length);
      this.minR = bank.minR ?? 3;
      this.root.classList.add("sds-quiz-ready");
      this.showStart();
    }

    // Pick the session's questions: at least minR R questions if the bank has
    // them, the rest at random, in random order.
    pick() {
      // A question is an R question if it says so ("r": true), or if it's a
      // fill, order or code question that doesn't say otherwise ("r": false).
      const isR = (q) => q.r ?? R_TYPES.includes(q.type);
      const rQs = shuffle(this.bank.questions.filter(isR));
      const take = rQs.slice(0, Math.min(this.minR, rQs.length, this.perSession));
      const rest = shuffle(this.bank.questions.filter((q) => !take.includes(q)));
      return shuffle(take.concat(rest.slice(0, this.perSession - take.length)));
    }

    // ---- Screens ------------------------------------------------------------------
    showStart() {
      const n = this.perSession;
      this.root.innerHTML = "";
      const card = el("div", { class: "sds-q-card sds-q-intro" }, `
        <div class="sds-q-badge" aria-hidden="true">?</div>
        <h2>${esc(this.bank.title)}</h2>
        <p>${n} questions, one at a time. Anything you miss comes back at the end until you've
          got every one right. Each quiz is a new random set, so take it as often as you like.</p>
        <button type="button" class="sds-q-btn sds-q-primary">Start quiz</button>`);
      card.querySelector("button").addEventListener("click", () => this.start());
      this.root.appendChild(card);
    }

    start() {
      this.session = uuid();
      this.items = this.pick().map((q) => ({ q, missed: false, done: false }));
      this.queue = this.items.slice();
      this.fixing = false;
      this.stats = { correct: 0, incorrect: 0, firstTry: 0 };
      if (this.items.some((i) => i.q.type === "code")) getWebR().catch(() => {});   // warm up R
      this.next();
    }

    next() {
      if (!this.queue.length) {
        const missed = this.items.filter((i) => !i.done);
        if (!missed.length) return this.finish();
        if (!this.fixing) {
          this.fixing = true;
          this.queue = shuffle(missed);
          return this.showFixIntro(missed.length);
        }
        this.queue = shuffle(missed);
      }
      this.current = this.queue.shift();
      this.showQuestion(this.current);
    }

    showFixIntro(n) {
      this.root.innerHTML = "";
      this.root.appendChild(this.progressBar());
      const card = el("div", { class: "sds-q-card sds-q-intro" }, `
        <div class="sds-q-badge sds-q-badge-fix" aria-hidden="true">↻</div>
        <h2>Let's fix ${n === 1 ? "the one" : "the " + n} you missed</h2>
        <p>${n === 1 ? "It comes" : "They come"} back now. Keep going until every question is right.</p>
        <button type="button" class="sds-q-btn sds-q-primary">Keep going</button>`);
      const btn = card.querySelector("button");
      btn.addEventListener("click", () => this.next());
      this.root.appendChild(card);
      btn.focus();
    }

    progressBar() {
      const done = this.items.filter((i) => i.done).length;
      const pct = Math.round((done / this.items.length) * 100);
      const wrap = el("div", { class: "sds-q-top" });
      wrap.innerHTML = `
        <div class="sds-q-progress" role="progressbar" aria-valuemin="0" aria-valuemax="${this.items.length}"
             aria-valuenow="${done}" aria-label="Questions answered correctly">
          <span style="width:${pct}%"></span></div>
        <div class="sds-q-count">${done} / ${this.items.length}</div>`;
      const btn = el("button", { type: "button", class: "sds-q-sound" });
      const label = () => {
        btn.textContent = soundOn ? "\u{1F50A}" : "\u{1F507}";
        btn.setAttribute("aria-pressed", String(soundOn));
        btn.setAttribute("aria-label", soundOn ? "Sound on. Turn sound off" : "Sound off. Turn sound on");
        btn.title = soundOn ? "Turn sound off" : "Turn sound on";
      };
      label();
      btn.addEventListener("click", () => { setSound(!soundOn); label(); if (soundOn) playSound("right"); });
      wrap.appendChild(btn);
      return wrap;
    }

    showQuestion(item) {
      const q = item.q;
      this.root.innerHTML = "";
      this.root.appendChild(this.progressBar());

      const card = el("div", { class: "sds-q-card" });
      if (this.fixing) card.appendChild(el("div", { class: "sds-q-tag" }, "Fix a mistake"));
      card.appendChild(el("h2", { class: "sds-q-prompt" }, md(q.prompt)));
      const body = el("div", { class: "sds-q-body" });
      card.appendChild(body);

      const footer = el("div", { class: "sds-q-footer" });
      const check = el("button", { type: "button", class: "sds-q-btn sds-q-primary", disabled: "" }, "Check");
      footer.appendChild(check);
      card.appendChild(footer);
      this.root.appendChild(card);

      const ready = (on) => { check.disabled = !on; };
      const answer = this.renderAnswer(q, body, ready, () => { if (!check.disabled) check.click(); });

      check.addEventListener("click", async () => {
        check.disabled = true;
        let result;
        try {
          result = await answer.check();
        } catch (e) {
          result = { correct: false, note: "Couldn't check that: " + (e.message || e) };
        }
        if (result.skip) return this.skip(item, footer);
        answer.lock();
        this.grade(item, result, footer);
      });
      answer.focus();
    }

    // Each answer type returns { check(): Promise<{correct, note?}>, lock(), focus() }.
    renderAnswer(q, body, ready, submit) {
      if (q.code && q.type !== "fill" && q.type !== "code") {
        body.appendChild(el("pre", { class: "sds-q-code" }, `<code>${esc(q.code)}</code>`));
      }
      switch (q.type) {
        case "choice": return this.renderChoice(q, body, ready, submit, shuffle(q.choices.map((c, i) => i)));
        case "truefalse": return this.renderChoice(q, body, ready, submit, null);
        case "fill": return this.renderFill(q, body, ready, submit);
        case "order": return this.renderOrder(q, body, ready);
        case "code": return this.renderCode(q, body, ready);
        default: throw new Error("Unknown question type: " + q.type);
      }
    }

    renderChoice(q, body, ready, submit, order) {
      const options = order
        ? order.map((i) => ({ label: q.choices[i], right: i === q.answer }))
        : [{ label: "True", right: q.answer === true }, { label: "False", right: q.answer === false }];
      const list = el("div", { class: "sds-q-choices", role: "radiogroup", "aria-label": "Answers" });
      let picked = null;
      const buttons = options.map((opt, n) => {
        const b = el("button", { type: "button", class: "sds-q-choice", role: "radio", "aria-checked": "false" },
          `<span class="sds-q-key">${n + 1}</span><span>${md(opt.label)}</span>`);
        b.addEventListener("click", () => {
          picked = opt;
          buttons.forEach((x) => x.setAttribute("aria-checked", String(x === b)));
          ready(true);
        });
        list.appendChild(b);
        return b;
      });
      body.appendChild(list);
      // Number keys pick an answer; Enter checks it.
      const onKey = (e) => {
        if (e.target.closest && e.target.closest("input, textarea")) return;
        const n = Number(e.key);
        if (n >= 1 && n <= buttons.length && !buttons[0].disabled) buttons[n - 1].click();
        else if (e.key === "Enter" && picked && !buttons[0].disabled) { e.preventDefault(); submit(); }
      };
      document.addEventListener("keydown", onKey);
      return {
        check: async () => ({ correct: picked.right }),
        lock: () => {
          document.removeEventListener("keydown", onKey);
          buttons.forEach((b, i) => {
            b.disabled = true;
            if (options[i].right) b.classList.add("is-right");
            else if (options[i] === picked) b.classList.add("is-wrong");
          });
        },
        focus: () => buttons[0].focus(),
      };
    }

    renderFill(q, body, ready, submit) {
      const input = el("input", {
        type: "text", class: "sds-q-input", autocomplete: "off", autocapitalize: "off",
        autocorrect: "off", spellcheck: "false", "aria-label": "Your answer",
      });
      if (q.code && q.code.includes("___")) {
        const [before, after] = q.code.split("___");
        const pre = el("pre", { class: "sds-q-code sds-q-code-fill" });
        const codeEl = el("code");
        codeEl.append(before);
        input.size = Math.max(4, Math.min(24, (q.answers[0] || "").length + 2));
        codeEl.appendChild(input);
        codeEl.append(after);
        pre.appendChild(codeEl);
        body.appendChild(pre);
      } else {
        input.classList.add("sds-q-input-wide");
        body.appendChild(input);
      }
      input.addEventListener("input", () => ready(input.value.trim() !== ""));
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); submit(); }
      });
      return {
        check: async () => ({ correct: fillIsRight(input.value, q) }),
        lock: () => { input.disabled = true; },
        focus: () => input.focus(),
      };
    }

    // Tiles: tap one in the bank to add it to your answer, tap it again to take it back.
    renderOrder(q, body, ready) {
      const answerLine = el("div", { class: "sds-q-line", "aria-label": "Your answer" });
      const bank = el("div", { class: "sds-q-bank", "aria-label": "Tiles" });
      const placeholder = el("span", { class: "sds-q-line-hint" }, "Tap the tiles in order");
      answerLine.appendChild(placeholder);
      const tiles = shuffle(q.answer.concat(q.extra || [])).map((text) => {
        const t = el("button", { type: "button", class: "sds-q-tile" }, esc(text));
        t.dataset.text = text;
        t.addEventListener("click", () => {
          (t.parentElement === bank ? answerLine : bank).appendChild(t);
          const any = answerLine.querySelector(".sds-q-tile") !== null;
          placeholder.hidden = any;
          ready(any);
        });
        bank.appendChild(t);
        return t;
      });
      body.appendChild(answerLine);
      body.appendChild(bank);
      const chosen = () => Array.from(answerLine.querySelectorAll(".sds-q-tile"), (t) => t.dataset.text);
      return {
        check: async () => ({ correct: chosen().join("\u0000") === q.answer.join("\u0000") }),
        lock: () => tiles.forEach((t) => { t.disabled = true; }),
        focus: () => tiles[0] && tiles[0].focus(),
      };
    }

    renderCode(q, body, ready) {
      const editor = el("textarea", {
        class: "sds-q-editor", spellcheck: "false", autocapitalize: "off", autocomplete: "off",
        "aria-label": "Your R code", rows: String(Math.max(4, (q.starter || "").split("\n").length + 2)),
      });
      editor.value = q.starter || "";
      const tools = el("div", { class: "sds-q-tools" });
      const run = el("button", { type: "button", class: "sds-q-btn sds-q-secondary" }, "▶ Run code");
      const status = el("span", { class: "sds-q-status", role: "status" });
      tools.append(run, status);
      const out = el("pre", { class: "sds-q-output", hidden: "" });
      body.append(editor, tools, out);

      // Tab inserts two spaces; Ctrl/Cmd+Enter runs.
      editor.addEventListener("keydown", (e) => {
        if (e.key === "Tab" && !e.shiftKey) {
          e.preventDefault();
          editor.setRangeText("  ", editor.selectionStart, editor.selectionEnd, "end");
        } else if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
          e.preventDefault();
          run.click();
        }
      });
      const typed = () => editor.value.trim() !== "" && editor.value.trim() !== (q.starter || "").trim();
      editor.addEventListener("input", () => ready(typed()));

      let rFailed = false;
      const show = (res) => {
        const text = res.error ? (res.output ? res.output + "\n" : "") + "Error: " + res.error : res.output;
        out.hidden = !text;
        out.textContent = text || "";
        out.classList.toggle("has-error", !!res.error);
      };
      const withR = async (fn) => {
        status.textContent = webRPromise ? "Running…" : "Starting R (the first time takes a few seconds)…";
        run.disabled = true;
        try {
          return await fn();
        } catch (e) {
          rFailed = true;
          status.textContent = "";
          out.hidden = false;
          out.classList.add("has-error");
          out.textContent = "R couldn't start in this browser (" + (e.message || e) + "). " +
            "Click Check to skip this question; it won't count against you.";
          ready(true);
          return null;
        } finally {
          run.disabled = false;
          if (!rFailed) status.textContent = "";
        }
      };
      run.addEventListener("click", () => withR(async () => show(await runR(editor.value))));

      return {
        check: async () => {
          if (rFailed) return { skip: true };
          const res = await withR(() => runR(editor.value, q.check));
          if (!res) return { skip: true };
          show(res);
          return {
            correct: res.passed,
            note: res.error ? "Your code stopped with an error, shown above." : null,
          };
        },
        lock: () => { editor.readOnly = true; run.disabled = true; },
        focus: () => {
          editor.focus();
          editor.setSelectionRange(editor.value.length, editor.value.length);
        },
      };
    }

    // ---- After Check -------------------------------------------------------------
    grade(item, result, footer) {
      const q = item.q;
      const firstTry = !item.missed && !this.fixing;
      if (result.correct) {
        this.stats.correct++;
        if (firstTry) this.stats.firstTry++;
        item.done = true;
      } else {
        this.stats.incorrect++;
        item.missed = true;
      }
      record("record_chapter_quiz_answer", {
        p_session: this.session, p_chapter: this.bank.id, p_chapter_title: this.bank.title,
        // The label includes the code, so "What does this code print?"
        // questions can be told apart on the admin page.
        p_size: this.items.length, p_question: q.id,
        p_label: q.code ? q.prompt + " " + q.code.replace(/\s*\n\s*/g, "; ") : q.prompt,
        p_correct: !!result.correct, p_first_try: firstTry,
      });

      // Update the bar straight away, as Duolingo does.
      const top = this.root.querySelector(".sds-q-top");
      if (top) top.replaceWith(this.progressBar());

      const right = !!result.correct;
      playSound(right ? "right" : "wrong");
      const sheet = el("div", { class: "sds-q-sheet " + (right ? "is-right" : "is-wrong"), role: "status" });
      let html = `<div class="sds-q-sheet-title">${right ? "Correct!" : "Not quite"}</div>`;
      if (result.note) html += `<p>${esc(result.note)}</p>`;
      if (!right) {
        const ans = correctAnswerText(q);
        // Code answers (fill-ins and R tile questions) are shown as code.
        const asCode = q.type === "fill" || (q.type === "order" && (q.r ?? true));
        if (ans) {
          html += q.type === "code"
            ? `<p>One answer that works:</p><pre class="sds-q-code"><code>${esc(ans)}</code></pre>`
            : asCode
              ? `<p>Correct answer: <code>${esc(ans)}</code></p>`
              : `<p>Correct answer: <strong>${md(ans)}</strong></p>`;
        }
      }
      if (q.explain) html += `<p class="sds-q-explain">${md(q.explain)}</p>`;
      if (!right) html += `<p class="sds-q-later">This one will come back at the end.</p>`;
      sheet.innerHTML = html;

      const cont = el("button", { type: "button", class: "sds-q-btn " + (right ? "sds-q-go" : "sds-q-danger") }, "Continue");
      cont.addEventListener("click", () => this.next());
      footer.replaceChildren(sheet, cont);
      footer.prepend(coach(right ? "happy" : "sad"));
      if (right && !reduceMotion()) footer.closest(".sds-q-card").classList.add("sds-q-pop");
      cont.focus();
    }

    // R wouldn't load: drop the question from this session without counting it.
    skip(item, footer) {
      this.items = this.items.filter((i) => i !== item);
      this.queue = this.queue.filter((i) => i !== item);
      const sheet = el("div", { class: "sds-q-sheet" },
        `<div class="sds-q-sheet-title">Skipped</div><p>This question needs R, which couldn't start here. It won't count.</p>`);
      const cont = el("button", { type: "button", class: "sds-q-btn sds-q-primary" }, "Continue");
      cont.addEventListener("click", () => this.next());
      footer.replaceChildren(sheet, cont);
      cont.focus();
    }

    finish() {
      record("record_chapter_quiz_finish", { p_session: this.session });
      const s = this.stats;
      const total = s.correct + s.incorrect;
      const success = total ? Math.round((s.correct / total) * 100) : 100;
      const n = this.items.length;
      const level = s.firstTry === n ? "perfect" : success >= 80 ? "great" : "done";
      const headline = { perfect: "Perfect!", great: "Great work!", done: "You did it!" }[level];
      const lines = FINISH_CHEERS[level];
      this.root.innerHTML = "";
      const card = el("div", { class: "sds-q-card sds-q-done" }, `
        <h2>${headline}</h2>
        <p>You answered all ${n} questions correctly.</p>
        <div class="sds-q-stats">
          <div><span class="n">${s.firstTry}/${n}</span><span class="l">right first try</span></div>
          <div><span class="n">${s.correct}</span><span class="l">correct answers</span></div>
          <div><span class="n">${s.incorrect}</span><span class="l">incorrect answers</span></div>
          <div><span class="n">${success}%</span><span class="l">success</span></div>
        </div>
        <div class="sds-q-actions">
          <button type="button" class="sds-q-btn sds-q-primary">New quiz</button>
        </div>`);
      card.prepend(coach("happy", lines[Math.floor(Math.random() * lines.length)]));
      const again = card.querySelector("button");
      again.addEventListener("click", () => this.start());
      this.root.appendChild(card);
      again.focus();
      playSound("finish");
      if (!reduceMotion()) confetti(this.root);
    }
  }

  // ---- Celebration -----------------------------------------------------------------
  function confetti(host) {
    const canvas = el("canvas", { class: "sds-q-confetti", "aria-hidden": "true" });
    host.appendChild(canvas);
    const ctx = canvas.getContext("2d");
    const dpr = window.devicePixelRatio || 1;
    const w = host.clientWidth, h = Math.max(host.clientHeight, 360);
    canvas.width = w * dpr; canvas.height = h * dpr;
    canvas.style.width = w + "px"; canvas.style.height = h + "px";
    ctx.scale(dpr, dpr);
    const colors = ["#58cc02", "#1cb0f6", "#ffc800", "#ff4b4b", "#ce82ff", "#2c5f8a"];
    const bits = Array.from({ length: 140 }, () => ({
      x: w / 2 + (Math.random() - 0.5) * 80, y: h * 0.32,
      vx: (Math.random() - 0.5) * 11, vy: -Math.random() * 11 - 4,
      size: 5 + Math.random() * 6, rot: Math.random() * Math.PI, vr: (Math.random() - 0.5) * 0.3,
      color: colors[Math.floor(Math.random() * colors.length)],
    }));
    const start = performance.now();
    (function frame(now) {
      const t = now - start;
      ctx.clearRect(0, 0, w, h);
      ctx.globalAlpha = Math.max(0, 1 - Math.max(0, t - 1800) / 900);
      for (const b of bits) {
        b.vy += 0.32; b.vx *= 0.99; b.x += b.vx; b.y += b.vy; b.rot += b.vr;
        ctx.save();
        ctx.translate(b.x, b.y); ctx.rotate(b.rot);
        ctx.fillStyle = b.color;
        ctx.fillRect(-b.size / 2, -b.size / 4, b.size, b.size / 2);
        ctx.restore();
      }
      if (t < 2700) requestAnimationFrame(frame); else canvas.remove();
    })(start);
  }

  // ---- Start -------------------------------------------------------------------
  async function init(root) {
    try {
      const res = await fetch(root.dataset.bank, { cache: "no-cache" });
      if (!res.ok) throw new Error("HTTP " + res.status);
      const bank = await res.json();
      if (!bank.id || !Array.isArray(bank.questions) || !bank.questions.length) {
        throw new Error("the question bank is empty or missing its id");
      }
      new Quiz(root, bank);
    } catch (e) {
      root.innerHTML = `<p class="sds-q-error">Couldn't load this quiz (${esc(e.message || e)}). Try reloading the page.</p>`;
    }
  }

  function boot() { document.querySelectorAll(".sds-quiz[data-bank]").forEach(init); }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
