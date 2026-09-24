(function () {
  "use strict";

  const DEFAULT_CONFIG = {
    photo_seconds: 20,
    content_reload_seconds: 60,
    interstitial_every_minutes: 10,
    interstitial_duration_seconds: 40,
    priority_rotation_seconds: 45,
    livecam_enabled: true,
    livecam_url: "https://www.greifenseewetter.ch/Kamera/greifensee2.jpg",
    livecam_every_minutes: 45,
    livecam_duration_seconds: 35,
    livecam_min_refresh_minutes: 15,
    quiz_enabled: true,
    quiz_every_minutes: 10,
    quiz_block_size: 3,
    quiz_question_seconds: 12,
    quiz_answer_seconds: 8,
    background: "#050506"
  };

  const els = {
    photoLayer: document.getElementById("photoLayer"),
    photoMain: document.getElementById("photoMain"),
    photoBlur: document.getElementById("photoBlur"),
    messageLayer: document.getElementById("messageLayer"),
    messageImage: document.getElementById("messageImage"),
    messageText: document.getElementById("messageText"),
    emptyLayer: document.getElementById("emptyLayer")
  };

  const state = {
    config: { ...DEFAULT_CONFIG },
    photos: [],
    news: [],
    infoImages: [],
    quiz: [],
    photoIndex: -1,
    lastPhotoUrl: "",
    lastMessageId: "",
    lastVariantKey: "",
    nextNormalMessageAt: 0,
    nextQuizAt: 0,
    nextLivecamAt: 0,
    livecamUrl: "",
    livecamUrlRefreshedAt: 0,
    quizSession: null,
    quizSeenIds: [],
    messageShownAt: {},
    messageVisibleUntil: 0,
    mode: "photo"
  };

  function seconds(value, fallback) {
    const n = Number(value);
    return Number.isFinite(n) && n > 0 ? n * 1000 : fallback * 1000;
  }

  function minutes(value, fallback) {
    return seconds(Number(value) * 60, fallback * 60);
  }

  function cacheBusted(path) {
    const sep = path.includes("?") ? "&" : "?";
    return `${path}${sep}t=${Date.now()}`;
  }

  async function fetchJSON(path, fallback) {
    try {
      const res = await fetch(cacheBusted(path), { cache: "no-store" });
      if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
      return await res.json();
    } catch (err) {
      console.warn("Content load failed:", path, err);
      return fallback;
    }
  }

  function parseLocalDate(value, endOfDay) {
    if (!value) return null;
    if (typeof value !== "string") return null;
    const trimmed = value.trim();
    const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/.exec(trimmed);
    if (dateOnly) {
      const y = Number(dateOnly[1]);
      const m = Number(dateOnly[2]) - 1;
      const d = Number(dateOnly[3]);
      return endOfDay
        ? new Date(y, m, d, 23, 59, 59, 999)
        : new Date(y, m, d, 0, 0, 0, 0);
    }

    const dt = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?$/.exec(trimmed);
    if (dt) {
      return new Date(
        Number(dt[1]),
        Number(dt[2]) - 1,
        Number(dt[3]),
        Number(dt[4]),
        Number(dt[5]),
        Number(dt[6] || 0),
        endOfDay ? 999 : 0
      );
    }

    const parsed = new Date(trimmed);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }

  function dateString(date) {
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
  }

  function isActive(item, now) {
    const from = parseLocalDate(item.valid_from, false);
    const until = parseLocalDate(item.valid_until, true);
    if (from && now < from) return false;
    if (until && now > until) return false;
    return true;
  }

  function normalizeInfoImage(image) {
    if (!image) return "";
    if (/^(https?:)?\/\//i.test(image) || image.startsWith("/")) return image;
    const clean = image.replace(/^info\//, "").replace(/^\/+/, "");
    return `/data/info/${encodeURIComponent(clean).replace(/%2F/g, "/")}`;
  }

  function stringList(...values) {
    return values
      .flatMap((value) => Array.isArray(value) ? value : [value])
      .map((value) => typeof value === "string" ? value.trim() : "")
      .filter(Boolean);
  }

  function firstString(...values) {
    return stringList(...values)[0] || "";
  }

  function eventTiming(item, now) {
    const event = parseLocalDate(item.event_date, false);
    if (!event) return "none";
    const today = dateString(now);
    const eventDay = dateString(event);
    if (today === eventDay) return "today";
    return today < eventDay ? "before" : "after";
  }

  function variantsForItem(item, now) {
    const timing = eventTiming(item, now);
    if (timing === "today") {
      return stringList(item.variants_today, item.today_variants, item.variants, item.text, item.bubble);
    }
    if (timing === "before") {
      return stringList(item.variants_before, item.before_variants, item.variants, item.text, item.bubble);
    }
    if (timing === "after") {
      return stringList(item.variants_after, item.after_variants, item.variants, item.text, item.bubble);
    }
    return stringList(item.variants, item.text, item.bubble);
  }

  function messageImportance(item) {
    const raw = String(item.importance || item.kind || item.category || item.type || "").toLowerCase();
    if (["background", "filler", "nice_to_have", "nice-to-have"].includes(raw)) return "filler";
    if (["event", "news", "important", "reminder"].includes(raw)) return "news";
    return item.event_date ? "news" : "filler";
  }

  function messageBucket(item, now) {
    if (item.priority) return "priority";
    if (messageImportance(item) === "filler") return "filler";
    const timing = eventTiming(item, now);
    if (timing === "today") return "today_news";
    if (timing === "before") return "upcoming_news";
    return "news";
  }

  function normalizeTextItem(item, now) {
    const variants = variantsForItem(item, now);
    if (!variants.length) return null;
    const id = item.id || variants[0].slice(0, 48);
    return {
      id: `news:${id}`,
      type: "text",
      variants,
      bucket: messageBucket(item, now),
      priority: !!item.priority,
      every_minutes: item.every_minutes,
      duration_sec: item.duration_sec,
      valid_from: item.valid_from,
      valid_until: item.valid_until,
      event_date: item.event_date,
      importance: messageImportance(item)
    };
  }

  function normalizeImageItem(item, now) {
    const image = normalizeInfoImage(item.image);
    const variants = stringList(item.caption_variants, item.variants, item.caption, item.text);
    if (!image && !variants.length) return null;
    const id = item.id || item.image || variants[0];
    return {
      id: `image:${id}`,
      type: "image",
      image,
      variants,
      bucket: messageBucket(item, now),
      priority: !!item.priority,
      every_minutes: item.every_minutes,
      duration_sec: item.duration_sec,
      valid_from: item.valid_from,
      valid_until: item.valid_until,
      event_date: item.event_date,
      importance: messageImportance(item)
    };
  }

  function normalizeQuizItem(item, index) {
    if (!item || typeof item !== "object") return null;
    const question = firstString(item.question, item.frage, item.Frage, item.text);
    const answer = firstString(item.answer, item.antwort, item.Antwort, item.solution, item.loesung);
    if (!question || !answer) return null;
    return {
      id: `quiz:${item.id || index + 1}`,
      question,
      answer
    };
  }

  function activeMessages(priorityOnly) {
    const now = new Date();
    const textItems = (state.news || [])
      .filter((item) => isActive(item, now))
      .map((item) => normalizeTextItem(item, now))
      .filter(Boolean);

    const imageItems = (state.infoImages || [])
      .filter((item) => isActive(item, now))
      .map((item) => normalizeImageItem(item, now))
      .filter(Boolean);

    return [...textItems, ...imageItems]
      .filter((item) => priorityOnly ? item.priority : !item.priority);
  }

  function pickItem(items) {
    if (!items.length) return null;
    const candidates = items.filter((item) => item.id !== state.lastMessageId);
    const pool = candidates.length ? candidates : items;
    return pool[Math.floor(Math.random() * pool.length)];
  }

  function weightedPick(groups) {
    const available = groups.filter(([, items, weight]) => items.length && weight > 0);
    if (!available.length) return null;
    const total = available.reduce((sum, [, , weight]) => sum + weight, 0);
    let r = Math.random() * total;
    for (const [, items, weight] of available) {
      r -= weight;
      if (r < 0) return pickItem(items);
    }
    return pickItem(available[available.length - 1][1]);
  }

  function chooseNormalMessage(items) {
    const groups = {
      today: items.filter((item) => item.bucket === "today_news"),
      upcoming: items.filter((item) => item.bucket === "upcoming_news" || item.bucket === "news"),
      filler: items.filter((item) => item.bucket === "filler")
    };

    if (groups.today.length) {
      return weightedPick([
        ["today", groups.today, 0.70],
        ["upcoming", groups.upcoming, 0.15],
        ["filler", groups.filler, 0.15]
      ]);
    }

    if (groups.upcoming.length) {
      return weightedPick([
        ["upcoming", groups.upcoming, 0.45],
        ["filler", groups.filler, 0.55]
      ]);
    }

    return pickItem(groups.filler);
  }

  function pickVariant(item) {
    const variants = item.variants || [];
    if (!variants.length) return "";
    const indexed = variants.map((text, index) => ({ text, key: `${item.id}:${index}` }));
    const candidates = indexed.filter((entry) => entry.key !== state.lastVariantKey);
    const pool = candidates.length ? candidates : indexed;
    const picked = pool[Math.floor(Math.random() * pool.length)];
    state.lastVariantKey = picked.key;
    return picked.text;
  }

  function overlayModes() {
    return ["priority", "interstitial", "livecam", "quiz_question", "quiz_answer"];
  }

  function setOverlayMode(mode) {
    for (const name of overlayModes()) {
      els.messageLayer.classList.toggle(name, name === mode);
    }
  }

  function hideMessage() {
    els.messageLayer.classList.add("hidden");
    setOverlayMode("");
    els.messageImage.classList.add("hidden");
    els.messageImage.removeAttribute("src");
    els.messageText.textContent = "";
    state.messageVisibleUntil = 0;
    state.mode = "photo";
  }

  function showMessage(item, fallbackDurationMs) {
    if (!item) return;
    state.lastMessageId = item.id;
    state.mode = item.mode || (item.priority ? "priority" : "interstitial");
    setOverlayMode(state.mode);

    if (item.image) {
      els.messageImage.src = item.image;
      els.messageImage.classList.remove("hidden");
    } else {
      els.messageImage.classList.add("hidden");
      els.messageImage.removeAttribute("src");
    }

    els.messageText.textContent = item.text || pickVariant(item);
    els.messageLayer.classList.remove("hidden");
    state.messageVisibleUntil = Date.now() + seconds(item.duration_sec, fallbackDurationMs / 1000);
  }

  function shuffledNextPhoto() {
    if (!state.photos.length) return null;
    if (state.photos.length === 1) return state.photos[0];

    let next = null;
    for (let i = 0; i < 8; i += 1) {
      next = state.photos[Math.floor(Math.random() * state.photos.length)];
      if (next.url !== state.lastPhotoUrl) break;
    }
    return next;
  }

  function showNextPhoto() {
    if (!state.photos.length) {
      els.emptyLayer.classList.remove("hidden");
      els.photoLayer.classList.remove("ready");
      return;
    }

    els.emptyLayer.classList.add("hidden");
    const photo = shuffledNextPhoto();
    if (!photo) return;

    state.lastPhotoUrl = photo.url;
    const url = cacheBusted(photo.url);
    const img = new Image();
    img.onload = () => {
      els.photoLayer.classList.remove("ready");
      window.setTimeout(() => {
        els.photoMain.src = url;
        els.photoBlur.src = url;
        els.photoLayer.classList.add("ready");
      }, 120);
    };
    img.src = url;
  }

  function shuffled(items) {
    const copy = [...items];
    for (let i = copy.length - 1; i > 0; i -= 1) {
      const j = Math.floor(Math.random() * (i + 1));
      [copy[i], copy[j]] = [copy[j], copy[i]];
    }
    return copy;
  }

  function pickQuizBlock() {
    if (!state.quiz.length) return [];
    const wanted = Math.max(1, Math.min(Number(state.config.quiz_block_size) || DEFAULT_CONFIG.quiz_block_size, state.quiz.length));
    const unseen = state.quiz.filter((item) => !state.quizSeenIds.includes(item.id));
    const pool = unseen.length >= wanted ? unseen : state.quiz;
    const block = shuffled(pool).slice(0, wanted);
    state.quizSeenIds = [...state.quizSeenIds, ...block.map((item) => item.id)].slice(-Math.max(50, state.quiz.length));
    return block;
  }

  function showQuizQuestion() {
    const session = state.quizSession;
    if (!session) return;
    const item = session.items[session.index];
    if (!item) return;
    session.phase = "question";
    showMessage({
      id: `${item.id}:question`,
      mode: "quiz_question",
      type: "text",
      variants: [`Quizfrage ${session.index + 1} von ${session.items.length}\n\n${item.question}`],
      duration_sec: state.config.quiz_question_seconds
    }, seconds(state.config.quiz_question_seconds, DEFAULT_CONFIG.quiz_question_seconds));
  }

  function showQuizAnswer() {
    const session = state.quizSession;
    if (!session) return;
    const item = session.items[session.index];
    if (!item) return;
    session.phase = "answer";
    showMessage({
      id: `${item.id}:answer`,
      mode: "quiz_answer",
      type: "text",
      variants: [`Antwort:\n\n${item.answer}`],
      duration_sec: state.config.quiz_answer_seconds
    }, seconds(state.config.quiz_answer_seconds, DEFAULT_CONFIG.quiz_answer_seconds));
  }

  function finishQuiz(now) {
    state.quizSession = null;
    state.nextQuizAt = now + minutes(state.config.quiz_every_minutes, DEFAULT_CONFIG.quiz_every_minutes);
    hideMessage();
  }

  function startQuizBlock(now) {
    const items = pickQuizBlock();
    if (!items.length) {
      state.nextQuizAt = now + minutes(state.config.quiz_every_minutes, DEFAULT_CONFIG.quiz_every_minutes);
      return false;
    }
    state.quizSession = { items, index: 0, phase: "question" };
    showQuizQuestion();
    return true;
  }

  function tickQuiz(now) {
    if (!state.quizSession) return false;
    if (["quiz_question", "quiz_answer"].includes(state.mode) && now < state.messageVisibleUntil) return true;

    if (state.quizSession.phase === "question") {
      showQuizAnswer();
      return true;
    }

    state.quizSession.index += 1;
    if (state.quizSession.index < state.quizSession.items.length) {
      showQuizQuestion();
      return true;
    }

    finishQuiz(now);
    return false;
  }

  function maybeStartQuiz(now) {
    if (state.config.quiz_enabled === false) return false;
    if (!state.quiz.length || now < state.nextQuizAt) return false;
    return startQuizBlock(now);
  }

  function livecamImageUrl(now) {
    const base = String(state.config.livecam_url || "").trim();
    if (!base) return "";
    const minRefreshMs = minutes(state.config.livecam_min_refresh_minutes, DEFAULT_CONFIG.livecam_min_refresh_minutes);
    if (!state.livecamUrl || !state.livecamUrl.startsWith(base) || now - state.livecamUrlRefreshedAt >= minRefreshMs) {
      state.livecamUrl = cacheBusted(base);
      state.livecamUrlRefreshedAt = now;
    }
    return state.livecamUrl;
  }

  function maybeShowLivecam(now) {
    if (state.config.livecam_enabled === false) return false;
    if (now < state.nextLivecamAt) return false;
    const image = livecamImageUrl(now);
    if (!image) return false;

    showMessage({
      id: "livecam:greifensee",
      mode: "livecam",
      type: "image",
      image,
      variants: ["Livecam Greifensee"],
      duration_sec: state.config.livecam_duration_seconds
    }, seconds(state.config.livecam_duration_seconds, DEFAULT_CONFIG.livecam_duration_seconds));

    state.nextLivecamAt = now + minutes(state.config.livecam_every_minutes, DEFAULT_CONFIG.livecam_every_minutes);
    return true;
  }

  async function loadContent() {
    const data = await fetchJSON("/api/content", {});
    state.config = { ...DEFAULT_CONFIG, ...(data.config || {}) };
    state.photos = Array.isArray(data.photos) ? data.photos : [];
    state.news = Array.isArray(data.news?.items) ? data.news.items : [];
    state.infoImages = Array.isArray(data.info_images?.items) ? data.info_images.items : [];
    state.quiz = Array.isArray(data.quiz?.items) ? data.quiz.items.map(normalizeQuizItem).filter(Boolean) : [];
    document.documentElement.style.setProperty("--bg", state.config.background || DEFAULT_CONFIG.background);
  }

  function tick() {
    const now = Date.now();
    const priority = activeMessages(true);

    if (priority.length) {
      if (state.mode !== "priority" || now >= state.messageVisibleUntil) {
        showMessage(pickItem(priority), seconds(state.config.priority_rotation_seconds, DEFAULT_CONFIG.priority_rotation_seconds));
      }
      return;
    }

    if (state.mode === "priority") hideMessage();

    if (tickQuiz(now)) return;

    if (["interstitial", "livecam"].includes(state.mode)) {
      if (now >= state.messageVisibleUntil) hideMessage();
      return;
    }

    if (maybeStartQuiz(now)) return;
    if (maybeShowLivecam(now)) return;

    const normalMessages = activeMessages(false);
    if (normalMessages.length && now >= state.nextNormalMessageAt) {
      const dueMessages = normalMessages.filter((item) => {
        const itemEveryMs = minutes(item.every_minutes || state.config.interstitial_every_minutes, DEFAULT_CONFIG.interstitial_every_minutes);
        const lastShown = state.messageShownAt[item.id] || 0;
        return !lastShown || now - lastShown >= itemEveryMs;
      });
      const item = chooseNormalMessage(dueMessages.length ? dueMessages : normalMessages);
      const quietMs = minutes(item?.every_minutes || state.config.interstitial_every_minutes, DEFAULT_CONFIG.interstitial_every_minutes);
      state.nextNormalMessageAt = now + quietMs;
      if (item) state.messageShownAt[item.id] = now;
      showMessage(item, seconds(state.config.interstitial_duration_seconds, DEFAULT_CONFIG.interstitial_duration_seconds));
    }
  }

  async function start() {
    await loadContent();
    const now = Date.now();
    state.nextNormalMessageAt = now + minutes(state.config.interstitial_every_minutes, DEFAULT_CONFIG.interstitial_every_minutes);
    state.nextQuizAt = now + minutes(state.config.quiz_every_minutes, DEFAULT_CONFIG.quiz_every_minutes);
    state.nextLivecamAt = now + minutes(state.config.livecam_every_minutes, DEFAULT_CONFIG.livecam_every_minutes);
    showNextPhoto();

    window.setInterval(loadContent, seconds(state.config.content_reload_seconds, DEFAULT_CONFIG.content_reload_seconds));
    window.setInterval(showNextPhoto, seconds(state.config.photo_seconds, DEFAULT_CONFIG.photo_seconds));
    window.setInterval(tick, 1000);
  }

  start();
}());
