-- gpodder-sync: gpodder.net subscription / progress sync for cliamp.
--
-- cliamp loads plugins as a single Lua file, so this plugin is organised as a
-- sequence of small modules (plain namespaced tables), each owning one concern:
--
--   util      pure helpers (base64, text, timestamp, collection utilities)
--   store     thin wrapper over cliamp.store (persistent per-plugin kv store)
--   config    typed access to [plugins.gpodder-sync] configuration
--   auth      credentials + Basic auth header
--   api       gpodder.net HTTP client (single base URL, auth, UA)
--   rss       minimal feed parsing (title + enclosure extraction)
--   device    gpodder.net device registration
--   subs      subscription list + incremental two-way sync + first-run adopt
--   actions   play actions (build / upload / queue / flush) and the resume store
--   metadata  per-feed metadata cache (titles + episode->feed mapping)
--   playlist  native podcasts.toml source built from enabled feeds
--   download  async episode download (yt-dlp/curl) + local-file registry
--   playback  position reporting and resume-on-open logic
--   engine    top-level workflows (login / logout / sync)
--
-- Everything below that is the cliamp wiring: commands, event hooks, keybinds.

local p = plugin.register({
    name = "gpodder-sync",
    type = "hook",
    version = "0.0.1",
    description = "Sync gpodder.net subscriptions, play history, progress and downloads for cliamp",
    permissions = { "keymap", "control", "exec" },
})

local USER_AGENT = "cliamp-gpodder-sync/0.0.1"

-- Tuning constants. Tune these in [plugins.gpodder-sync] config where noted.
local STORE_LIMIT = 1000 -- max entries kept in any plugin store table
local QUEUE_LIMIT = 500 -- max buffered play actions waiting to upload
local RESUME = {
    min_position = 15, -- ignore stored positions before this many seconds in
    max_fraction = 0.9, -- ignore stored positions this close to the end
    seek_tolerance = 2, -- consider the seek done within this many seconds
    seek_retries = 4, -- seek attempts before giving up (stream buffering)
    seek_delay = 1.0, -- seconds between seek attempts
}

local util = {}

util.b64encode = (function()
    local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    return function(s)
        local out = {}
        local i = 1
        while i <= #s do
            local c1 = s:byte(i)
            local c2 = s:byte(i + 1)
            local c3 = s:byte(i + 2)
            local n = c1 * 65536 + (c2 or 0) * 256 + (c3 or 0)
            local pos = #out + 1
            out[pos] = B64:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
            out[pos + 1] = B64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
            out[pos + 2] = (i + 1 <= #s) and B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
            out[pos + 3] = (i + 2 <= #s) and B64:sub(n % 64 + 1, n % 64 + 1) or "="
            i = i + 3
        end
        return table.concat(out)
    end
end)()

function util.trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function util.has(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

function util.filter(list, pred)
    local out = {}
    for _, v in ipairs(list) do
        if pred(v) then table.insert(out, v) end
    end
    return out
end

function util.prune(tbl, max)
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    if count <= max then return tbl end
    local keys = {}
    for k in pairs(tbl) do table.insert(keys, k) end
    local keep = {}
    for i = count - max + 1, count do
        keep[keys[i]] = tbl[keys[i]]
    end
    return keep
end

function util.iso_timestamp()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function util.iso_to_epoch(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, sec = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):?(%d*)")
    if not y then return nil end
    sec = (sec and sec ~= "") and tonumber(sec) or 0
    local function days_from_civil(y, m, d)
        y = y - ((m <= 2) and 1 or 0)
        local era = math.floor(y / 400)
        local yoe = y - era * 400
        local mp = (m + 9) % 12
        local doy = math.floor((153 * mp + 2) / 5) + d - 1
        local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
        return era * 146097 + doe - 719468
    end
    local days = days_from_civil(tonumber(y), tonumber(mo), tonumber(d))
    return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + sec
end

function util.sanitize(s)
    s = s:gsub("[^%w_-]", "-")
    s = s:gsub("-+", "-")
    return s
end


-- store: persistent per-plugin kv store wrapper
local store = {
    get = function(key) return cliamp.store.get(key) end,
    set = function(key, value) cliamp.store.set(key, value) end,
    delete = function(key) cliamp.store.delete(key) end,
}


-- config: typed access to [plugins.gpodder-sync]
local config = {}

function config.get(key, default)
    local v = p:config(key)
    if v == nil then return default end
    return v
end

function config.bool(key, default)
    local v = p:config(key)
    if v == nil then return default end
    if v == true or v == "true" or v == "1" or v == "yes" or v == "on" then return true end
    if v == false or v == "false" or v == "0" or v == "no" or v == "off" then return false end
    return default
end


-- auth: credentials + Basic auth header
local auth = {}

function auth.username()
    return config.get("username") or store.get("username")
end

function auth.password()
    return config.get("password") or store.get("password")
end

function auth.header()
    local user = auth.username()
    local pass = auth.password()
    if not user or not pass then return nil end
    return "Basic " .. util.b64encode(user .. ":" .. pass)
end


-- api: gpodder.net HTTP client
local api = {}

function api.base_url()
    return (config.get("server", "https://gpodder.net")):gsub("/+$", "")
end

local function api_headers(extra)
    local headers = { ["User-Agent"] = USER_AGENT }
    local header = auth.header()
    if header then headers.Authorization = header end
    if extra then
        for k, v in pairs(extra) do headers[k] = v end
    end
    return headers
end

function api.get(path)
    return cliamp.http.get(api.base_url() .. path, { headers = api_headers() })
end

function api.post(path, payload)
    return cliamp.http.post(api.base_url() .. path, {
        json = payload,
        headers = api_headers(),
    })
end


-- rss: minimal feed parsing (titles + enclosures)
local rss = {}

function rss.decode_xml(s)
    s = s:gsub("&amp;", "&")
    s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&#39;", "'")
    s = s:gsub("&#(%d+);", function(n) return string.char(tonumber(n)) end)
    return s
end

function rss.title(body)
    if not body then return nil end
    local t = body:match("<title>(.-)</title>")
    if not t then return nil end
    t = rss.decode_xml(t)
    t = t:gsub("^%s*<!%[CDATA%[", ""):gsub("%]%]>%s*$", "")
    t = t:gsub("%s+", " ")
    t = util.trim(t)
    if t == "" then return nil end
    return t
end

function rss.enclosures(body)
    local out = {}
    for url in body:gmatch('<enclosure[^>]*url="([^"]+)"[^>]*/?>') do
        out[#out + 1] = rss.decode_xml(url)
    end
    for url in body:gmatch("<enclosure[^>]*url='([^']+)'[^>]*/?>") do
        out[#out + 1] = rss.decode_xml(url)
    end
    return out
end

function rss.fetch(url)
    local ok, body, status = pcall(cliamp.http.get, url, { headers = { ["User-Agent"] = USER_AGENT } })
    if not ok or status ~= 200 or not body or body == "" then return nil end
    return body
end


-- device: gpodder.net device registration
local device = {}

function device.default_id()
    local host = os.getenv("HOSTNAME") or os.getenv("COMPUTERNAME") or os.getenv("USER") or "desktop"
    local id = "cliamp-" .. util.sanitize(host)
    if #id > 32 then id = id:sub(1, 32) end
    return id
end

function device.id()
    local id = store.get("device_id") or config.get("device_id")
    if not id then
        id = device.default_id()
        store.set("device_id", id)
    end
    return id
end

function device.caption()
    return config.get("device_name", "cliamp on " .. (os.getenv("HOSTNAME") or os.getenv("USER") or "this machine"))
end

function device.register()
    local user = auth.username()
    if not user then return false, "no username configured" end
    local id = device.id()
    local body, status = api.post("/api/2/devices/" .. user .. "/" .. id .. ".json", {
        caption = device.caption(),
        type = "desktop",
    })
    if status == 200 or status == 201 or status == 204 then
        store.set("device_registered", true)
        return true, "device '" .. id .. "' registered"
    end
    return false, "device registration failed (HTTP " .. tostring(status) .. ")"
end


-- subs: subscription two-way sync + first-run adoption
local subs = {}

function subs.list()
    return store.get("subscriptions") or {}
end

function subs.save(list)
    store.set("subscriptions", list)
end

function subs.apply_updates(list, update_urls)
    if not update_urls then return list end
    for _, pair in ipairs(update_urls) do
        local old, new = pair[1], pair[2]
        if new and new ~= "" then
            for i, url in ipairs(list) do
                if url == old then list[i] = new end
            end
        end
    end
    return list
end

function subs.pull()
    local user = auth.username()
    if not user then return false, "no username configured" end
    local id = device.id()
    local since = store.get("sub_since") or 0
    local path = "/api/2/subscriptions/" .. user .. "/" .. id .. ".json?since=" .. tostring(since)
    local body, status = api.get(path)
    if status == 404 then
        device.register()
        body, status = api.get(path)
    end
    if status ~= 200 then
        return false, "pull failed (HTTP " .. tostring(status) .. ")"
    end
    local data = cliamp.json.decode(body)
    if not data then return false, "pull returned invalid JSON" end
    local list = subs.list()
    for _, url in ipairs(data.add or {}) do
        if not util.has(list, url) then table.insert(list, url) end
    end
    for _, url in ipairs(data.remove or {}) do
        list = util.filter(list, function(x) return x ~= url end)
    end
    list = subs.apply_updates(list, data.update_urls)
    if data.timestamp then store.set("sub_since", data.timestamp) end
    subs.save(list)
    return true, "pulled " .. #(data.add or {}) .. " added, " .. #(data.remove or {}) .. " removed"
end

function subs.push()
    local user = auth.username()
    if not user then return false, "no username configured" end
    local add = store.get("pending_add") or {}
    local remove = store.get("pending_remove") or {}
    if #add == 0 and #remove == 0 then return true, "no local changes" end
    local body, status = api.post("/api/2/subscriptions/" .. user .. "/" .. device.id() .. ".json", {
        add = add,
        remove = remove,
    })
    if status ~= 200 then
        return false, "push failed (HTTP " .. tostring(status) .. ")"
    end
    local data = cliamp.json.decode(body)
    local list = subs.list()
    if data then
        list = subs.apply_updates(list, data.update_urls)
        if data.timestamp then store.set("sub_since", data.timestamp) end
    end
    for _, url in ipairs(add) do
        if not util.has(list, url) then table.insert(list, url) end
    end
    for _, url in ipairs(remove) do
        list = util.filter(list, function(x) return x ~= url end)
    end
    subs.save(list)
    store.set("pending_add", {})
    store.set("pending_remove", {})
    return true, "pushed " .. #add .. " add(s), " .. #remove .. " remove(s)"
end

function subs.add(url)
    url = util.trim(url)
    if url == "" then return false, "empty feed url" end
    local list = subs.list()
    if util.has(list, url) then return true, "already subscribed: " .. url end
    local add = store.get("pending_add") or {}
    local remove = store.get("pending_remove") or {}
    if util.has(add, url) then return true, "already queued to add: " .. url end
    store.set("pending_remove", util.filter(remove, function(x) return x ~= url end))
    table.insert(add, url)
    store.set("pending_add", add)
    table.insert(list, url)
    subs.save(list)
    return true, "subscribed locally; run 'gpodder-sync sync' to upload: " .. url
end

function subs.remove(url)
    url = util.trim(url)
    if url == "" then return false, "empty feed url" end
    local add = store.get("pending_add") or {}
    local remove = store.get("pending_remove") or {}
    store.set("pending_add", util.filter(add, function(x) return x ~= url end))
    if not util.has(remove, url) then table.insert(remove, url) end
    store.set("pending_remove", remove)
    subs.save(util.filter(subs.list(), function(x) return x ~= url end))
    return true, "unsubscribed locally; run 'gpodder-sync sync' to upload: " .. url
end

function subs.should_adopt()
    if store.get("adopted") then return false end
    if #subs.list() > 0 then return false end
    return true
end

function subs.adopt()
    local user = auth.username()
    if not user then return false, "no username configured" end
    local list = subs.list()
    local seen = {}
    for _, url in ipairs(list) do seen[url] = true end
    local added = {}
    local function collect(dev_id)
        if not dev_id or dev_id == "" then return end
        local body, status = api.get("/api/2/subscriptions/" .. user .. "/" .. dev_id .. ".json?since=0")
        if status ~= 200 or not body then return end
        local data = cliamp.json.decode(body)
        for _, url in ipairs(data and data.add or {}) do
            if not seen[url] then
                seen[url] = true
                table.insert(added, url)
            end
        end
    end
    local devices_ok = false
    local body, status = api.get("/api/2/devices/" .. user .. ".json")
    if status == 200 and body then
        devices_ok = true
        local devices = cliamp.json.decode(body)
        for _, dev in ipairs(devices or {}) do
            collect(dev and dev.id)
        end
    end
    collect(device.id())
    if #added == 0 then
        if devices_ok then store.set("adopted", true) end
        return true, "no new subscriptions to adopt"
    end
    for _, url in ipairs(added) do table.insert(list, url) end
    subs.save(list)
    local pending = store.get("pending_add") or {}
    for _, url in ipairs(added) do
        if not util.has(pending, url) then table.insert(pending, url) end
    end
    store.set("pending_add", pending)
    store.set("adopted", true)
    return true, "adopted " .. #added .. " new subscription(s) from your devices; run 'gpodder-sync sync' to upload"
end


-- actions: play actions + resume store
local actions = {}

function actions.build(feed, episode, position, total)
    return {
        podcast = feed,
        episode = episode,
        device = device.id(),
        action = "play",
        started = os.time(),
        position = position,
        total = total,
        timestamp = util.iso_timestamp(),
    }
end

function actions.pull()
    local user = auth.username()
    if not user then return false, "no username configured" end
    local since = store.get("actions_since")
    if not since then return true, "skipped (no baseline timestamp yet; play a podcast to set one)" end
    local body, status = api.get("/api/2/episodes/" .. user .. ".json?since=" .. tostring(since) .. "&aggregated=true")
    if status ~= 200 then
        return false, "pull actions failed (HTTP " .. tostring(status) .. ")"
    end
    local data = cliamp.json.decode(body)
    if not data then return false, "pull actions returned invalid JSON" end
    if data.timestamp then store.set("actions_since", data.timestamp) end
    local stored = store.get("resume") or {}
    for _, action in ipairs(data.actions or {}) do
        local ep = action.episode
        if ep then
            local pos = tonumber(action.position) or 0
            if pos > 0 then
                local ts = util.iso_to_epoch(action.timestamp) or 0
                local cur = stored[ep]
                if not cur or ts >= cur.ts then
                    stored[ep] = { position = pos, total = tonumber(action.total) or 0, ts = ts }
                end
            end
        end
    end
    store.set("resume", util.prune(stored, STORE_LIMIT))
    return true, "stored " .. #(data.actions or {}) .. " episode action(s)"
end

function actions.upload(list)
    if not list or #list == 0 then return true end
    local user = auth.username()
    if not user then
        actions.queue(list)
        return false, "no username configured"
    end
    local body, status = api.post("/api/2/episodes/" .. user .. ".json", list)
    if status ~= 200 then
        actions.queue(list)
        return false, "upload actions failed (HTTP " .. tostring(status) .. ")"
    end
    local data = cliamp.json.decode(body)
    if data and data.timestamp then store.set("actions_since", data.timestamp) end
    return true
end

function actions.queue(list)
    local queued = store.get("pending_actions") or {}
    for _, action in ipairs(list) do
        queued[#queued + 1] = action
    end
    store.set("pending_actions", util.prune(queued, QUEUE_LIMIT))
end

function actions.flush()
    local queued = store.get("pending_actions") or {}
    if #queued == 0 then return true, "no pending actions" end
    local user = auth.username()
    if not user then return false, "no username configured" end
    local body, status = api.post("/api/2/episodes/" .. user .. ".json", queued)
    if status ~= 200 then
        return false, "flush failed (HTTP " .. tostring(status) .. ")"
    end
    local data = cliamp.json.decode(body)
    if data and data.timestamp then store.set("actions_since", data.timestamp) end
    store.set("pending_actions", {})
    return true, "flushed " .. #queued .. " pending action(s)"
end

function actions.feed_for(episode)
    if not episode then return nil end
    local map = store.get("episode_feed")
    if not map then return nil end
    return map[episode]
end

function actions.episode_for(path)
    if not path then return nil end
    local files = store.get("local_files")
    if not files then return path end
    return files[path] or path
end

function actions.feed_for_path(path)
    if not path then return nil end
    local episode = actions.episode_for(path)
    return actions.feed_for(episode) or actions.feed_for(path)
end

function actions.resume_for(episode)
    if not episode then return nil end
    local resume = store.get("resume")
    if not resume then return nil end
    return resume[episode]
end

function actions.record(path, position, total)
    if not path then return nil end
    if not position or position <= 0 then return nil end
    local episode = actions.episode_for(path)
    local feed = actions.feed_for_path(path)
    if not feed then return nil end
    local resume = store.get("resume") or {}
    resume[episode] = { position = position, total = total or 0, ts = os.time() }
    store.set("resume", util.prune(resume, STORE_LIMIT))
    return feed
end

function actions.remember_local(path, episode_url)
    if not path or not episode_url then return end
    local files = store.get("local_files") or {}
    files[path] = episode_url
    store.set("local_files", util.prune(files, STORE_LIMIT))
end

function actions.remember_feed(feed_url, body)
    if not body then return end
    local map = store.get("episode_feed") or {}
    for _, ep in ipairs(rss.enclosures(body)) do
        map[ep] = feed_url
    end
    store.set("episode_feed", util.prune(map, STORE_LIMIT))
end

function actions.map_episode(episode, feed_url)
    if not episode then return end
    local map = store.get("episode_feed") or {}
    map[episode] = feed_url
    store.set("episode_feed", util.prune(map, STORE_LIMIT))
end

-- playback: position reporting and resume-on-open.
--
-- Report boundaries:
--   * report()   records locally AND uploads (scrobble, quit, periodic tick)
--   * upload()   uploads only (used after a record-only pass)
--   * record()   lives on the actions module and is store-only
-- All of them no-op for anything that doesn't resolve to a known podcast feed,
-- so regular music playback never touches gpodder.net.

local playback = {}

function playback.upload(path, position, total)
    if not config.bool("scrobble", true) then return end
    if not path then return end
    if not position or position <= 0 then return end
    local feed = actions.feed_for_path(path)
    if not feed then return end
    actions.upload({
        actions.build(feed, actions.episode_for(path), position, total or 0),
    })
end

function playback.report(path, position, total)
    if not config.bool("scrobble", true) then return end
    if not path then return end
    if not actions.record(path, position or 0, total or 0) then return end
    playback.upload(path, position or 0, total or 0)
end

function playback.resume_to(path)
    if not path then return end
    local episode = actions.episode_for(path)
    local resume = actions.resume_for(episode)
    if not resume or not resume.position then return end
    if resume.position < RESUME.min_position then return end
    if resume.total and resume.total > 0 and resume.position >= resume.total * RESUME.max_fraction then return end
    local attempt = 0
    local function try_seek()
        attempt = attempt + 1
        if attempt > RESUME.seek_retries then return end
        local current = cliamp.player.position()
        if current and current >= resume.position - RESUME.seek_tolerance then return end
        cliamp.player.seek(resume.position)
        cliamp.timer.after(RESUME.seek_delay, try_seek)
    end
    cliamp.timer.after(RESUME.seek_delay, try_seek)
end

-- metadata: per-feed titles + episode->feed mapping
local metadata = {}

function metadata.refresh(url)
    local body = rss.fetch(url)
    if not body then return false end
    local title = rss.title(body)
    if title then
        local titles = store.get("feed_titles") or {}
        titles[url] = title
        store.set("feed_titles", titles)
    end
    actions.remember_feed(url, body)
    return true
end

function metadata.forget(url)
    local titles = store.get("feed_titles") or {}
    if titles[url] then
        titles[url] = nil
        store.set("feed_titles", titles)
    end
    local map = store.get("episode_feed")
    if map then
        local cleaned = {}
        for ep, feed in pairs(map) do
            if feed ~= url then cleaned[ep] = feed end
        end
        store.set("episode_feed", cleaned)
    end
end


-- playlist: native podcasts.toml source from enabled feeds
local playlist = {}

function playlist.dir()
    return (os.getenv("HOME") or "") .. "/.config/cliamp/playlists"
end

function playlist.path()
    return playlist.dir() .. "/podcasts.toml"
end

function playlist.is_enabled(url)
    local enabled = store.get("feed_enabled") or {}
    return enabled[url] ~= false
end

function playlist.set_enabled(url, on)
    local enabled = store.get("feed_enabled") or {}
    enabled[url] = on and true or false
    store.set("feed_enabled", enabled)
end

function playlist.enabled()
    local enabled = store.get("feed_enabled") or {}
    return util.filter(subs.list(), function(url) return enabled[url] ~= false end)
end

function playlist.title_for(url)
    local titles = store.get("feed_titles") or {}
    if titles[url] and titles[url] ~= "" then return titles[url] end
    local host = url:gsub("^https?://", ""):gsub("/.*$", ""):gsub("^www%.", "")
    return host
end

local function toml_escape(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\r", " "):gsub("\n", " ")
    return '"' .. s .. '"'
end

function playlist.write()
    local urls = playlist.enabled()
    local lines = { "# generated by cliamp-plugin-gpodder-sync -- do not edit" }
    for _, url in ipairs(urls) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = "[[track]]"
        lines[#lines + 1] = "path = " .. toml_escape(url)
        lines[#lines + 1] = "title = " .. toml_escape(playlist.title_for(url))
        lines[#lines + 1] = "feed = true"
    end
    local ok, err = pcall(function()
        cliamp.fs.mkdir(playlist.dir())
        cliamp.fs.write(playlist.path(), table.concat(lines, "\n") .. "\n")
    end)
    if not ok then
        return false, "could not write " .. playlist.path() .. " (" .. tostring(err) .. ")"
    end
    return true, "wrote " .. #urls .. " feed(s) to " .. playlist.path()
end

function playlist.sync_sources()
    local urls = playlist.enabled()
    local refreshed = 0
    for _, url in ipairs(urls) do
        if metadata.refresh(url) then refreshed = refreshed + 1 end
    end
    local ok, msg = playlist.write()
    if not ok then return false, msg end
    return true, "refreshed " .. refreshed .. "/" .. #urls .. " feed(s); " .. msg
end


-- download: async episode downloads + local-file registry
local download = {
    active = {},
}

function download.base_dir()
    local dir = config.get("download_dir")
    if not dir then
        dir = (os.getenv("HOME") or "") .. "/Music/cliamp/gpodder"
    end
    return dir:gsub("/+$", "")
end

function download.dest_dir(feed_url)
    local slug = "podcast"
    if feed_url then
        slug = util.sanitize(playlist.title_for(feed_url))
    end
    if slug == "" then slug = "podcast" end
    return download.base_dir() .. "/" .. slug
end

function download.registry()
    return store.get("downloaded") or {}
end

function download.remember(episode_url, path)
    local map = download.registry()
    map[episode_url] = path
    store.set("downloaded", util.prune(map, STORE_LIMIT))
end

function download.find_local(episode_url)
    local path = download.registry()[episode_url]
    if path and cliamp.fs.exists(path) then return path end
    return nil
end

local function play_local(path, feed_url, episode_url)
    actions.remember_local(path, episode_url)
    actions.map_episode(episode_url, feed_url)
    local okq, res = pcall(cliamp.queue.add, path)
    if not okq or res == false then
        cliamp.message("gpodder: could not queue " .. path)
        return false
    end
    local idx = cliamp.queue.count() - 1
    if idx >= 0 then cliamp.queue.jump(idx) end
    return true
end

function download.start(episode_url, feed_url)
    if download.active[episode_url] then
        return false, "already downloading: " .. episode_url
    end
    local local_path = download.find_local(episode_url)
    if local_path then
        play_local(local_path, feed_url, episode_url)
        return true, "already downloaded; playing " .. local_path
    end
    local dir = download.dest_dir(feed_url)
    local ok = pcall(cliamp.fs.mkdir, dir)
    if not ok then return false, "cannot create download dir " .. dir end

    local tool = config.get("downloader") or "yt-dlp"
    local args, dest
    if tool == "curl" then
        local ext = episode_url:match("%.([%w]+)$") or "mp3"
        dest = dir .. "/cliamp-" .. tostring(os.time()) .. "." .. ext
        args = { "-L", "--fail", "--silent", "--show-error", "--max-time", "600", "-o", dest, episode_url }
    else
        tool = "yt-dlp"
        args = { "-o", dir .. "/%(title)s.%(ext)s", "--print", "after_move:filepath", "--no-playlist", episode_url }
    end

    local job = { url = episode_url, feed = feed_url, tool = tool, dest = dest }
    local handle, err = cliamp.exec.run(tool, args, {
        on_stdout = function(line) job.last_out = util.trim(line) end,
        on_exit = function(code) download.finish(job, code) end,
        timeout = 1800,
    })
    if not handle then
        return false, "cannot start " .. tool .. ": " .. tostring(err)
    end
    download.active[episode_url] = job
    return true, "downloading episode -> " .. dir
end

function download.finish(job, code)
    if download.active[job.url] then download.active[job.url] = nil end
    if code ~= 0 then
        cliamp.message("gpodder: download failed (exit " .. tostring(code) .. ")")
        cliamp.log.error("download failed: " .. job.url .. " (exit " .. tostring(code) .. ")")
        return
    end
    local path = job.dest
    if job.tool == "yt-dlp" and job.last_out and job.last_out ~= "" and not job.last_out:find("%.part$") then
        path = job.last_out
    end
    if not path or not cliamp.fs.exists(path) then
        cliamp.message("gpodder: download finished but file not found")
        cliamp.log.warn("download finished but file not found: " .. tostring(path or job.url))
        return
    end
    cliamp.message("gpodder: downloaded " .. path)
    cliamp.log.info("downloaded " .. path)
    download.remember(job.url, path)
    play_local(path, job.feed, job.url)
end


-- engine: top-level workflows (login / logout / sync)
local engine = {
    syncing = false,
}

function engine.login()
    local user = auth.username()
    if not user then return false, "no username configured" end
    if not auth.password() then return false, "no password configured" end
    local body, status = api.post("/api/2/auth/" .. user .. "/login.json", {})
    if status == 200 then
        cliamp.message("gpodder: logged in as " .. user)
        return true, "logged in as " .. user
    end
    return false, "login failed (HTTP " .. tostring(status) .. ")"
end

function engine.logout()
    local user = auth.username()
    if user then
        api.post("/api/2/auth/" .. user .. "/logout.json", {})
    end
    for _, key in ipairs({
        "username", "password", "device_id", "device_registered",
        "sub_since", "actions_since", "subscriptions", "adopted",
        "pending_add", "pending_remove", "episode_feed", "resume",
        "feed_enabled", "feed_titles", "pending_actions", "local_files",
    }) do
        store.delete(key)
    end
    cliamp.message("gpodder: logged out")
    return "logged out and cleared local sync state"
end

function engine.sync()
    if engine.syncing then return false, "sync already in progress" end
    if not auth.username() then return false, "not configured; run 'gpodder-sync login <user> <pass>'" end
    engine.syncing = true
    local results = {}
    local ok = true
    local function step(label, fn)
        local s, msg = fn()
        if s then
            table.insert(results, label .. ": " .. msg)
        else
            ok = false
            table.insert(results, label .. " FAILED: " .. msg)
        end
    end
    local dev_ok, dev_msg = device.register()
    if not dev_ok then ok = false end
    table.insert(results, "device: " .. dev_msg)
    if subs.should_adopt() then
        step("adopt", subs.adopt)
    end
    step("pull", subs.pull)
    step("push", subs.push)
    step("playlist", playlist.sync_sources)
    step("actions", actions.pull)
    step("pending", actions.flush)
    engine.syncing = false
    if ok then cliamp.message("gpodder: sync complete") end
    return ok, table.concat(results, "\n")
end

function engine.auto_sync()
    if engine.syncing then return end
    if not auth.username() then return end
    engine.syncing = true
    local ok = pcall(function()
        if not store.get("device_registered") then device.register() end
        if subs.should_adopt() then subs.adopt() end
        subs.pull()
        subs.push()
        actions.flush()
        playlist.write()
    end)
    engine.syncing = false
    if ok then
        cliamp.log.info("auto-sync complete")
    else
        cliamp.log.warn("auto-sync failed")
    end
end


-- cliamp wiring: commands
p:command("help", function()
    return table.concat({
        "gpodder-sync commands:",
        "  login [user] [pass]   verify credentials (credentials also via config.toml)",
        "  logout                clear credentials and local sync state",
        "  sync                  full two-way subscription sync",
        "  adopt                 pull subscriptions from all your devices into cliamp",
        "  pull                  fetch subscription changes from gpodder.net",
        "  push                  upload pending subscription changes",
        "  subscriptions         list synced feed urls",
        "  subscribe <url>       add a feed subscription locally",
        "  unsubscribe <url>     remove a feed subscription locally",
        "  feeds                 list synced feeds and whether they sync to cliamp",
        "  feed on|off <url>     include/exclude a feed in the cliamp podcast source",
        "  playlist              regenerate the podcasts.toml source from synced feeds",
        "  download [url]        download an episode and play it (feed url = latest episode)",
        "  downloads             list downloaded files",
        "  positions             list stored resume positions per episode",
        "  status                show configuration and sync state",
    }, "\n")
end)

p:command("login", function(args)
    local user = args[1]
    local pass = args[2]
    if user then store.set("username", user) end
    if pass then store.set("password", pass) end
    local ok, msg = engine.login()
    return msg
end)

p:command("logout", function()
    return engine.logout()
end)

p:command("sync", function()
    local ok, msg = engine.sync()
    return msg
end)

p:command("adopt", function()
    local ok, msg = subs.adopt()
    if ok then
        playlist.sync_sources()
        cliamp.message("gpodder: " .. msg)
    end
    return msg
end)

p:command("pull", function()
    local ok, msg = subs.pull()
    return msg
end)

p:command("push", function()
    local ok, msg = subs.push()
    return msg
end)

p:command("subscriptions", function()
    local list = subs.list()
    if #list == 0 then return "no subscriptions synced yet" end
    return table.concat(list, "\n")
end)

p:command("subscribe", function(args)
    local url = util.trim(args[1] or "")
    local ok, msg = subs.add(url)
    if ok and msg:match("subscribed locally") then
        metadata.refresh(url)
        playlist.write()
    end
    return msg
end)

p:command("unsubscribe", function(args)
    local url = util.trim(args[1] or "")
    local ok, msg = subs.remove(url)
    if ok and msg:match("unsubscribed locally") then
        metadata.forget(url)
        playlist.write()
    end
    return msg
end)

p:command("feeds", function()
    local urls = subs.list()
    if #urls == 0 then return "no subscriptions synced yet" end
    local lines = {}
    for _, url in ipairs(urls) do
        local mark = playlist.is_enabled(url) and "[on] " or "[off]"
        lines[#lines + 1] = mark .. playlist.title_for(url) .. "  " .. url
    end
    return table.concat(lines, "\n")
end)

p:command("feed", function(args)
    local mode, url = args[1], util.trim(args[2] or "")
    if (mode ~= "on" and mode ~= "off") or url == "" then
        return "usage: gpodder-sync feed on|off <feed-url>"
    end
    if not util.has(subs.list(), url) then
        return "not a synced subscription: " .. url
    end
    playlist.set_enabled(url, mode == "on")
    local ok, msg = playlist.write()
    return (mode == "on" and "enabled feed in cliamp; " or "disabled feed in cliamp; ") .. msg
end)

p:command("playlist", function()
    local ok, msg = playlist.sync_sources()
    return msg
end)

p:command("download", function(args)
    local url = util.trim(args[1] or "")
    if url == "" then
        if not cliamp.track.is_stream() then
            return "usage: gpodder-sync download <episode-url|feed-url> (or play a stream first)"
        end
        url = cliamp.track.path()
    end
    local feed
    if util.has(subs.list(), url) then
        feed = url
        local body = rss.fetch(url)
        if not body then return "could not fetch feed: " .. url end
        local eps = rss.enclosures(body)
        if #eps == 0 then return "no downloadable episodes found in " .. url end
        url = eps[1]
    else
        feed = actions.feed_for(url)
    end
    local ok, msg = download.start(url, feed)
    cliamp.log.info(msg)
    return msg
end)

p:command("downloads", function()
    local dir = download.base_dir()
    local names = cliamp.fs.listdir(dir)
    if not names then return "no downloads directory yet: " .. dir end
    if #names == 0 then return "no downloads in " .. dir end
    local lines = {}
    for _, name in ipairs(names) do
        lines[#lines + 1] = dir .. "/" .. name
    end
    table.sort(lines)
    return table.concat(lines, "\n")
end)

p:command("positions", function()
    local stored = store.get("resume") or {}
    local lines = {}
    for episode, pos in pairs(stored) do
        table.insert(lines, tostring(pos.position or 0) .. "s / " .. tostring(pos.total or 0) .. "s " .. episode)
    end
    if #lines == 0 then return "no episode positions stored yet" end
    table.sort(lines)
    return table.concat(lines, "\n")
end)

p:command("status", function()
    return table.concat({
        "username: " .. (auth.username() or "(not set)"),
        "server: " .. api.base_url(),
        "device: " .. (store.get("device_id") or config.get("device_id") or "(none)"),
        "subscriptions: " .. #subs.list(),
        "feeds: " .. #playlist.enabled() .. " enabled / " .. #subs.list() .. " synced",
        "sub_since: " .. tostring(store.get("sub_since") or 0),
        "actions_since: " .. tostring(store.get("actions_since") or 0),
        "pending_add: " .. #(store.get("pending_add") or {}),
        "pending_remove: " .. #(store.get("pending_remove") or {}),
    }, "\n")
end)


-- cliamp wiring: event hooks
p:on("track.scrobble", function(track)
    playback.report(track.path, track.duration or track.played_secs or 0, track.duration or 0)
end)

p:on("playback.state", function(ev)
    if not ev.path then return end
    if not config.bool("scrobble", true) then return end
    actions.record(ev.path, ev.position or 0, ev.duration or 0)
    if ev.status == "paused" or ev.status == "stopped" then
        playback.upload(ev.path, ev.position or 0, ev.duration or 0)
    end
end)

p:on("track.change", function(track)
    playback.resume_to(track.path)
end)

p:on("app.quit", function()
    local path = cliamp.track.path()
    if not path then return end
    playback.report(path, cliamp.player.position() or 0, cliamp.player.duration() or 0)
end)

p:on("app.start", function()
    if config.bool("auto_sync", true) then
        local interval = tonumber(config.get("sync_interval_secs", 3600)) or 3600
        cliamp.timer.every(interval, engine.auto_sync)
        cliamp.log.info("auto-sync enabled (every " .. interval .. "s)")
    end
    cliamp.timer.every(tonumber(config.get("flush_interval_secs", 300)) or 300, function()
        if not auth.username() then return end
        actions.flush()
    end)
    cliamp.timer.every(tonumber(config.get("position_sync_secs", 30)) or 30, function()
        if cliamp.player.state() ~= "playing" then return end
        local path = cliamp.track.path()
        if not path then return end
        playback.report(path, cliamp.player.position() or 0, cliamp.player.duration() or 0)
    end)
    playlist.write()
end)


-- cliamp wiring: keybinds
p:bind("ctrl+g", "gpodder: sync", function()
    local ok, msg = engine.sync()
    cliamp.log.info(msg)
end)

p:bind("ctrl+p", "gpodder: podcasts", function()
    local ok, msg = playlist.sync_sources()
    cliamp.message(msg)
    cliamp.log.info(msg)
end)

local okbind, bindreason = p:bind("alt+d", "gpodder: download & play current", function()
    if not cliamp.track.is_stream() then
        cliamp.message("gpodder: current track is not a stream")
        return
    end
    local url = cliamp.track.path()
    local ok, msg = download.start(url, actions.feed_for(url))
    cliamp.message("gpodder: " .. msg)
    cliamp.log.info(msg)
end)
if not okbind then cliamp.log.warn("could not bind alt+d: " .. tostring(bindreason)) end
