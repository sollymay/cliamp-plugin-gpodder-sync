# Changelog

## [0.0.2] - 2026-08-14

### Fixed

- **HTTP timeouts no longer break sync.** `cliamp.http` raises a Lua error on transport
  failures (it caps requests at 5s), and `api.get`/`api.post` passed that straight through. A
  slow gpodder.net response could throw out of `actions.pull`, `actions.upload`, etc., and a
  throwing step in `engine.sync` left `syncing` stuck on `true` — every later sync then failed
  with "sync already in progress" until restart. All HTTP calls are now `pcall`-guarded (returning
  `status 0` on transport errors, handled like any non-200 response) and every sync step runs in
  its own `pcall`, so a failed step is reported but sync keeps running and the flag is always
  released.
- Queued play actions and resume positions continue to be retried on the next `sync` / flush
  timer, so nothing is lost on a timeout.
- **`sync` no longer crashes on device registration.** `pcall(device.register)` was assigning the
  boolean returned by `device.register` to the message variable, so `"device: " .. <boolean>`
  raised a concat error and `ctrl+g` reported `keybind ctrl+g error` instead of syncing. The
  result and message are now captured separately, and a failed registration marks the sync as
  failed rather than silently succeeding.

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
