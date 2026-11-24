--!nonstrict
-- The only place that runs the provider commands. There is one service for the
-- whole shell, however many monitors carry the widget, and it publishes what it
-- learns through `noctalia.state`:
--
--   snapshot  { data = { <provider> = reading }, failure = { <provider> = text } }
--   busy      true while any command is running
--   request   (written by the bar and the panel) { at, force, maxAge }
--
-- Each provider is polled independently: a failure on one side never hides a
-- good reading from another.

local model = require("./lib/model.luau")

-- The slowest command may legitimately take ~20s (an app-server handshake); the
-- host's 5s default would kill it half way and leave its temp files behind.
local TIMEOUT_MS = 30000

local data = {}
local failure = {}
local startedAt = {}
local polledAt = {}
local queued = {}

local lastSnapshot = nil
local lastBusy = nil

local function refreshSeconds()
  return math.max(30, tonumber(model.conf("refresh_seconds")) or 120)
end

local function everySeconds(provider)
  return math.max(refreshSeconds(), provider.minSeconds or 0)
end

local function publish()
  local snapshot = { data = data, failure = failure }
  local encoded = noctalia.json.encode(snapshot)
  if encoded ~= lastSnapshot then
    lastSnapshot = encoded
    noctalia.state.set("snapshot", snapshot)
  end
  local busy = next(startedAt) ~= nil
  if busy ~= lastBusy then
    lastBusy = busy
    noctalia.state.set("busy", busy)
  end
end

-- The commands explain themselves on stderr ("claude-usage: no credentials at
-- …"); that beats anything the plugin could guess from an exit code.
local function explain(provider, res)
  if res.timedOut then return noctalia.tr("error.timeout") end
  for line in tostring(res.stderr or ""):gmatch("[^\r\n]+") do
    local text = noctalia.string.trim(line:gsub("^[%w%-]+%-usage:%s*", ""))
    if text ~= "" then return text end
  end
  return noctalia.tr("error.failed", { code = tostring(res.exitCode) })
end

local pollOne, schedule

local function finish(provider, res)
  local key = provider.key
  startedAt[key] = nil
  if not model.enabled(provider) then
    data[key], failure[key] = nil, nil
  elseif res.exitCode ~= 0 or res.timedOut then
    failure[key] = explain(provider, res)
  else
    local ok, reading = pcall(noctalia.json.decode, res.stdout)
    if ok and type(reading) == "table" then
      data[key], failure[key] = reading, nil
    else
      failure[key] = noctalia.tr("error.bad_output")
    end
  end
  if queued[key] then
    queued[key] = nil
    pollOne(provider, true, 0)
  end
  schedule()
  publish()
end

function pollOne(provider, force, maxAge)
  local key = provider.key
  local now = model.now()
  -- A command that never reported back (a reload ate its callback) must not lock
  -- the provider out for good.
  if startedAt[key] and now - startedAt[key] < TIMEOUT_MS / 1000 + 15 then
    -- A forced refresh deserves an answer newer than the click.
    if force then queued[key] = true end
    return
  end

  polledAt[key] = now
  local bin = noctalia.expandPath(tostring(model.conf(provider.setting)))
  if bin:sub(1, 1) == "/" and not noctalia.fileExists(bin) then
    failure[key] = noctalia.tr("error.not_found", { path = bin })
    return
  end

  local argv = { bin, "--bar-json" }
  if force then
    table.insert(argv, "--refresh")
  else
    table.insert(argv, "--max-age")
    table.insert(argv, tostring(maxAge))
  end
  startedAt[key] = now
  -- The host caps concurrent commands; when it declines, the next tick retries.
  local accepted = noctalia.runAsync(argv, function(res) finish(provider, res) end, TIMEOUT_MS)
  if not accepted then
    startedAt[key] = nil
    polledAt[key] = nil
  end
end

local function poll(force, maxAge)
  for _, provider in ipairs(model.PROVIDERS) do
    if model.enabled(provider) then pollOne(provider, force, maxAge) end
  end
  schedule()
  publish()
end

-- When a provider is due again. Readings also arrive through the timer and the
-- shell, so the age of the reading decides; when that says nothing (a failure, or
-- Antigravity, which is pushed) the last attempt does.
local function dueAt(provider)
  local polled = polledAt[provider.key]
  if not polled then return 0 end
  local every = everySeconds(provider)
  local reading = data[provider.key]
  if reading and not reading.stale and not failure[provider.key] then
    local due = (tonumber(reading.fetched_at) or 0) + every
    if due > polled then return math.min(due, polled + every) end
  end
  return polled + every
end

-- Wake up for whichever provider is due first: a fixed tick would round every
-- other interval up to its own multiples.
function schedule()
  local soonest = model.now() + refreshSeconds()
  for _, provider in ipairs(model.PROVIDERS) do
    if model.enabled(provider) then soonest = math.min(soonest, dueAt(provider)) end
  end
  noctalia.setUpdateInterval(math.max(5, soonest - model.now()) * 1000)
end

function update()
  local now = model.now()
  for _, provider in ipairs(model.PROVIDERS) do
    if model.enabled(provider) and now >= dueAt(provider) then
      -- Accept what someone else fetched since our reading, but not our reading.
      pollOne(provider, false, everySeconds(provider) - 15)
    end
  end
  schedule()
  publish()
end

function onConfigChanged()
  for _, provider in ipairs(model.PROVIDERS) do
    if not model.enabled(provider) then
      data[provider.key], failure[provider.key] = nil, nil
    end
  end
  poll(false, refreshSeconds())
end

-- Whatever was learned before a suspend is old by definition.
function onResume()
  polledAt = {}
  poll(false, 15)
end

-- noctalia msg plugin dankhael/dank-tank:poller all refresh
function onIpc(event)
  if event == "refresh" then poll(true, 0) end
end

noctalia.state.watch("request", function(request)
  if type(request) ~= "table" then return end
  poll(request.force and true or false, tonumber(request.maxAge) or 30)
end)

update()
