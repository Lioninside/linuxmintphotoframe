// Linux Mint photo frame kiosk profile preferences.

user_pref("browser.startup.page", 1);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_welcome_url", "");
user_pref("startup.homepage_welcome_url.additional", "");

// Avoid prompts and visible download UI on a kiosk screen.
user_pref("browser.download.useDownloadDir", true);
user_pref("browser.download.alwaysOpenPanel", false);
user_pref("browser.download.manager.addToRecentDocs", false);

// Keep normal profile storage. The kiosk URL is local, but this avoids future
// surprises if a signed-in service is ever used in the same profile.
user_pref("privacy.clearOnShutdown.cache", false);
user_pref("privacy.clearOnShutdown.cookies", false);
user_pref("privacy.clearOnShutdown.downloads", false);
user_pref("privacy.clearOnShutdown.formdata", false);
user_pref("privacy.clearOnShutdown.history", false);
user_pref("privacy.clearOnShutdown.sessions", false);
user_pref("privacy.sanitize.sanitizeOnShutdown", false);
user_pref("browser.privatebrowsing.autostart", false);

// Limit decoded-image cache growth on long-running kiosk sessions.
user_pref("image.mem.max_decoded_image_kb", 262144);
