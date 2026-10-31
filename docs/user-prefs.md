# Per-user interface settings

Language, theme, the last page and tab, and a few Canvas panel states are kept **for the signed-in user in the database**, so they follow the person to any browser. The browser stores nothing (the session token stays in `sessionStorage` for the tab only).

- Table `user_ui_prefs`: one row per user, a JSON object of short text values. Removed with the user.
- Actions `me.prefs_get` and `me.prefs_set` (`prefs`: an object; a `null` value clears that key). Any signed-in user, for themselves only.
- Names are lowercase words (`lang`, `theme`, `ui.page`, `canvas.help_seen`); values are text of at most 200 characters; at most 64 settings. `lang` must be a language code and `theme` is `light` or `dark`.
- The dashboard reads them right after sign-in and saves a change a moment after it is made (language and theme at once). The Canvas reads them before it draws and saves its own.
- The sign-in screen has no user yet, so it is always in English. If a save fails the dashboard says so and the setting lasts until the page is closed.
- Old `localStorage` values from earlier versions are not read.
