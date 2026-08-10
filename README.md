# cliamp-plugin-gpodder-sync

A [cliamp](https://docs.cliamp.stream/docs/cliamp/lua-plugins) plugin that connects cliamp to
[gpodder.net](https://gpodder.net) — or any [gPodder API 2](https://gpoddernet.readthedocs.io/en/latest/api/)
compatible server — so your podcast subscriptions and listening position follow you across devices.

## Features

- **Sign in** with HTTP Basic auth, either from `config.toml` or interactively via `login`.
- **Subscription sync** — pull remote subscription changes, push local adds/removes.
- **First-run adoption** — imports subscriptions from *all* your devices on the first sync, so your
  existing podcast library appears without manual setup.
- **Position sync** — pushes a `play` action with the current position every **30 seconds** while
  playing, and immediately on pause/stop, quit, and scrobble.
- **Unified resume** — the streamed copy, the downloaded copy, and the gpodder.net position all
  share one resume spot per episode; opening any of them resumes where you left off.
- **Podcast source** — exposes synced feeds as a native `podcasts.toml` playlist
  (`~/.config/cliamp/playlists/podcasts.toml`), browsable under **Local Playlists** in cliamp.
- **Feed selection** — per-feed control over which subscriptions appear in cliamp with
  `feed on|off`, without dropping the gpodder subscription.
- **Download & play** — save an episode to disk with `download` (or `alt+d`), then switch to the
  local copy when it lands.
- **Auto-sync** — background timers keep subscriptions and queued actions in sync while cliamp runs.

## Install

```sh
mkdir -p ~/.config/cliamp/plugins
cp gpodder-sync.lua ~/.config/cliamp/plugins/
cliamp plugins trust gpodder-sync
```

Or install from the repository:

```sh
cliamp plugins install sollymay/cliamp-plugin-gpodder-sync
```

## Configure

Credentials and options live in `config.toml` under `[plugins.gpodder-sync]`:

```toml
[plugins.gpodder-sync]
username = "your-gpodder-username"
password = "your-gpodder-password"

# optional
# server             = "https://gpodder.net"   # or a self-hosted gPodder server
# device_id          = "cliamp-desktop"        # stable device identifier
# device_name        = "cliamp on desktop"
# sync_interval_secs = 3600                    # subscription auto-sync interval
# flush_interval_secs = 300                    # queued-action retry interval
# position_sync_secs = 30                      # how often live position is uploaded
# auto_sync          = true
# scrobble           = true                    # report play actions to gpodder.net
# download_dir       = "~/Music/cliamp/gpodder" # where downloaded episodes land
# downloader         = "yt-dlp"                # "yt-dlp" (default) or "curl"
```

Downloads run through cliamp's `exec` capability. `yt-dlp` is allowlisted by default; to use
`curl` instead, add it to the allowlist in `config.toml`:

```toml
[plugins]
allowed_binaries = "curl"   # merged with the default yt-dlp/ffmpeg allowlist
```

If you'd rather not keep credentials in the config file, log in at runtime instead:

```sh
cliamp plugins call gpodder-sync login your-username your-password
```

Credentials are then stored in the plugin's private store (owner-only permissions).

## Usage

```sh
cliamp plugins call gpodder-sync login [user] [pass]   # verify credentials
cliamp plugins call gpodder-sync adopt                 # pull subs from all your devices now
cliamp plugins call gpodder-sync sync                  # full two-way subscription sync
cliamp plugins call gpodder-sync subscriptions         # list synced feed URLs
cliamp plugins call gpodder-sync subscribe <feed-url>  # add a subscription
cliamp plugins call gpodder-sync unsubscribe <feed-url># remove a subscription
cliamp plugins call gpodder-sync feeds                 # list feeds and their sync status
cliamp plugins call gpodder-sync feed on <feed-url>    # include a feed in the podcast source
cliamp plugins call gpodder-sync feed off <feed-url>   # exclude a feed from the podcast source
cliamp plugins call gpodder-sync playlist              # rewrite podcasts.toml now
cliamp plugins call gpodder-sync download <url>        # download an episode & play it (feed url = latest episode)
cliamp plugins call gpodder-sync downloads             # list downloaded files
cliamp plugins call gpodder-sync positions             # stored resume positions per episode
cliamp plugins call gpodder-sync pull                  # fetch subscription changes only
cliamp plugins call gpodder-sync push                  # upload pending subscription changes
cliamp plugins call gpodder-sync status                # show config and sync state
cliamp plugins call gpodder-sync logout                # clear credentials and local state
```

Inside cliamp: `ctrl+g` runs a sync, `ctrl+p` refreshes the podcast source, and `alt+d` downloads
and plays the current episode. Browse your podcasts under **Local Playlists → podcasts**
(`Esc` or `b`), then pick a feed to load its latest episodes.

## How it works

The plugin speaks the gPodder API 2 protocol:

- **Auth** — `POST /api/2/auth/<user>/login.json` with HTTP Basic auth.
- **Device** — a stable device id (`cliamp-<hostname>` by default) is registered via
  `POST /api/2/devices/<user>/<device>.json`; the server auto-creates it on first use.
- **Subscriptions** — incremental two-way sync via
  `GET/POST /api/2/subscriptions/<user>/<device>.json` with a `since` timestamp. The list and
  timestamp live in the plugin store, so a fresh device pulls the full list on first sync.
- **Adoption** — when cliamp has no synced subscriptions yet, `sync`/`adopt` enumerates the
  device list (`GET /api/2/devices/<user>.json`), collects each device's subscriptions, and
  queues the union for upload to the cliamp device.
- **Episode actions** — `POST /api/2/episodes/<user>.json` pushes `play` actions carrying
  position/total for episodes the user actually plays. Only episodes mapped to a known podcast
  feed are reported, so local music files are ignored.
- **Resume store** — playback position is recorded on every pause/stop/seek, on quit, and every
  `position_sync_secs` while playing, keyed by the canonical episode URL. Downloads resolve back
  to that URL through a local-file registry, so progress for the local copy updates the same
  episode as the streamed version. When an episode opens, the plugin seeks to the stored spot
  (skipped within the first 15 seconds or past 90% of the episode). Pulls from gpodder.net merge
  into the same store with newest-timestamp-wins, so a position set on another device resumes
  here too.
- **Podcast source** — sync rewrites `podcasts.toml` with one `feed = true` track per enabled
  feed. cliamp reads that as a native playlist source and resolves episodes itself. Feed titles
  are cached from each feed's `<title>` (URL-derived fallback).

## Notes

- cliamp caps HTTP calls at 5 seconds; if an upload times out, the action is queued locally and
  retried every `flush_interval_secs` and on `sync`, so positions are never lost.
- Only public network addresses are reachable (`cliamp.http` blocks private/loopback), so a
  self-hosted server must be publicly reachable.
- `subscribe`/`unsubscribe` change the local list and queue the change; run `sync` to push it.
- **Downloading** needs `yt-dlp` (default) or `curl`; it runs async (up to 30 min) via
  `cliamp.exec` and plays the file once finished. Files land in
  `~/Music/cliamp/gpodder/<feed-title>/` (override with `download_dir`). Because the plugin
  declares `exec` and `control` permissions, re-approve it after updating
  (`cliamp plugins trust gpodder-sync`).
- **One copy per episode** — a registry of downloaded episodes (episode URL → file path) means
  re-requesting a download that's already on disk just plays the cached file; deleting the file
  re-downloads it on the next request.
- The podcast source is rewritten after `sync`, `adopt`, `subscribe`, `unsubscribe`,
  `feed on|off`, and once at startup. If cliamp is already running, open the provider browser
  (`Esc`/`b`) or press `ctrl+p` to reload it.

## Development

Single-file plugin, no external dependencies. cliamp loads plugins as one Lua file, so the code
is organised as a sequence of small namespaced modules (see the header of `gpodder-sync.lua`),
each owning a single concern: HTTP, subscriptions, actions, resume, playlist, downloads, and the
cliamp wiring (commands, hooks, keybinds) at the end.

Sandbox notes: no `io`/`os.execute`, so all network goes through `cliamp.http` and a pure-Lua
base64 encoder provides Basic auth.
