# Changelog

## [0.0.1] - 2026-08-10

Initial release of `cliamp-plugin-gpodder-sync`.

### Added

- **Sign in** to gpodder.net (or any gPodder API 2 compatible server) via `login` or
  `[plugins.gpodder-sync]` config.
- **Subscription sync** — incremental two-way sync of subscriptions with a `since` timestamp.
- **First-run adoption** — imports subscriptions from all of your devices on first sync.
- **Position sync** — `play` actions with position/total are uploaded every 30 seconds while
  playing and immediately on pause/stop, quit, and scrobble. Timeouts are queued and retried so
  positions are never lost.
- **Unified resume** — streamed, downloaded, and gpodder.net-synced playback share one position
  per episode. Opening an episode seeks to the stored spot (skipped near the start or end);
  server positions merge into the same store with newest-timestamp-wins.
- **Podcast source** — synced feeds exposed as a native `podcasts.toml` playlist, with per-feed
  enable/disable (`feed on|off`).
- **Download & play** — asynchronous episode download via `yt-dlp` or `curl`, with a persistent
  registry so re-requesting a downloaded episode plays the cached file.
- **Auto-sync** — background timers for subscription sync, queued-action retries, and live
  position reporting.
- **Commands** — `login`, `logout`, `sync`, `adopt`, `pull`, `push`, `subscriptions`,
  `subscribe`, `unsubscribe`, `feeds`, `feed on|off`, `playlist`, `download`, `downloads`,
  `positions`, `status`, `help`.

### Architecture

- Single-file plugin (cliamp loads plugins as one Lua file), organised as small namespaced
  modules: `util`, `store`, `config`, `auth`, `api`, `rss`, `device`, `subs`, `actions`,
  `metadata`, `playlist`, `download`, `playback`, `engine`, with cliamp wiring (commands, hooks,
  keybinds) at the end.
- Consistent `(ok, message)` return convention and `STORE_LIMIT` / `QUEUE_LIMIT` / `RESUME`
  tuning constants.
