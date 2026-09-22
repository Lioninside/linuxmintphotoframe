(function () {
  "use strict";

  const DEFAULT_CONFIG = {
    photo_seconds: 20,
    content_reload_seconds: 60,
    interstitial_every_minutes: 10,
    interstitial_duration_seconds: 40,
    priority_rotation_seconds: 45,
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
    photoIndex: -1,
    lastPhotoUrl: "",
    lastMessageId: "",
    nextNormalMessageAt: 0,
    messageShownAt: {},
    messageVisibleUntil: 0,
    mode: "photo"
  };

  function seconds(value, fallback) {
    const n = Number(value);
    return Number.isFinite(n) && n > 0 ? n * 1000 : fallback * 1000;
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

  function activeMessages(priorityOnly) {
    const now = new Date();
    const textItems = (state.news || []).map((item) => ({
      id: `news:${item.id || item.text}`,
      type: "text",
      text: item.text || item.bubble || "",
      priority: !!item.priority,
      every_minutes: item.every_minutes,
      duration_sec: item.duration_sec,
      valid_from: item.valid_from,
      valid_until: item.valid_until
    }));

    const imageItems = (state.infoImages || []).map((item) => ({
      id: `image:${item.id || item.image}`,
      type: "image",
      image: normalizeInfoImage(item.image),
      text: item.caption || item.text || "",
      priority: !!item.priority,
      every_minutes: item.every_minutes,
      duration_sec: item.duration_sec,
      valid_from: item.valid_from,
      valid_until: item.valid_until
    }));

    return [...textItems, ...imageItems]
      .filter((item) => item.text || item.image)
      .filter((item) => isActive(item, now))
      .filter((item) => priorityOnly ? item.priority : !item.priority);
  }

  function pickItem(items) {
    if (!items.length) return null;
    const candidates = items.filter((item) => item.id !== state.lastMessageId);
    const pool = candidates.length ? candidates : items;
    return pool[Math.floor(Math.random() * pool.length)];
  }

  function hideMessage() {
    els.messageLayer.classList.add("hidden");
    els.messageImage.classList.add("hidden");
    els.messageImage.removeAttribute("src");
    els.messageText.textContent = "";
    state.messageVisibleUntil = 0;
    state.mode = "photo";
  }

  function showMessage(item, fallbackDurationMs) {
    if (!item) return;
    state.lastMessageId = item.id;
    state.mode = item.priority ? "priority" : "interstitial";

    if (item.image) {
      els.messageImage.src = item.image;
      els.messageImage.classList.remove("hidden");
    } else {
      els.messageImage.classList.add("hidden");
      els.messageImage.removeAttribute("src");
    }

    els.messageText.textContent = item.text || "";
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

  async function loadContent() {
    const data = await fetchJSON("/api/content", {});
    state.config = { ...DEFAULT_CONFIG, ...(data.config || {}) };
    state.photos = Array.isArray(data.photos) ? data.photos : [];
    state.news = Array.isArray(data.news?.items) ? data.news.items : [];
    state.infoImages = Array.isArray(data.info_images?.items) ? data.info_images.items : [];
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

    if (state.mode === "interstitial") {
      if (now >= state.messageVisibleUntil) hideMessage();
      return;
    }

    const normalMessages = activeMessages(false);
    if (normalMessages.length && now >= state.nextNormalMessageAt) {
      const dueMessages = normalMessages.filter((item) => {
        const itemEveryMs = seconds(
          Number(item.every_minutes || state.config.interstitial_every_minutes) * 60,
          DEFAULT_CONFIG.interstitial_every_minutes * 60
        );
        const lastShown = state.messageShownAt[item.id] || 0;
        return !lastShown || now - lastShown >= itemEveryMs;
      });
      const item = pickItem(dueMessages.length ? dueMessages : normalMessages);
      const quietMs = seconds(
        Number(item?.every_minutes || state.config.interstitial_every_minutes) * 60,
        DEFAULT_CONFIG.interstitial_every_minutes * 60
      );
      state.nextNormalMessageAt = now + quietMs;
      if (item) state.messageShownAt[item.id] = now;
      showMessage(item, seconds(state.config.interstitial_duration_seconds, DEFAULT_CONFIG.interstitial_duration_seconds));
    }
  }

  async function start() {
    await loadContent();
    state.nextNormalMessageAt = Date.now() + seconds(
      state.config.interstitial_every_minutes * 60,
      DEFAULT_CONFIG.interstitial_every_minutes * 60
    );
    showNextPhoto();

    window.setInterval(loadContent, seconds(state.config.content_reload_seconds, DEFAULT_CONFIG.content_reload_seconds));
    window.setInterval(showNextPhoto, seconds(state.config.photo_seconds, DEFAULT_CONFIG.photo_seconds));
    window.setInterval(tick, 1000);
  }

  start();
}());
