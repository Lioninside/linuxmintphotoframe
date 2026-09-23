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
    lastVariantKey: "",
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

    els.messageText.textContent = pickVariant(item);
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
      const item = chooseNormalMessage(dueMessages.length ? dueMessages : normalMessages);
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
