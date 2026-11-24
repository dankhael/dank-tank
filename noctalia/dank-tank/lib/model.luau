--!nonstrict
-- What the bar and the panel both need to know: which providers exist, how their
-- readings turn into one normalised list of agents, and how numbers are spelled.
--
-- Nothing here touches a surface or runs a command. The service publishes raw
-- readings, and everything that depends on the clock (countdowns, pace, whether a
-- window has already rolled over) is worked out at draw time, so an old reading
-- ages correctly without anyone polling again.

local M = {}

M.PANEL = "dankhael/dank-tank:detail"

M.PROVIDERS = {
  { key = "claude", letter = "C", setting = "command", toggle = "show_claude" },
  -- Each Codex query starts a local app-server, which costs far more than the
  -- plain HTTP reads, so it gets a floor of its own.
  { key = "codex", letter = "X", setting = "codex_command", toggle = "show_codex", minSeconds = 300 },
  { key = "antigravity", letter = "A", setting = "antigravity_command", toggle = "show_antigravity" },
  { key = "opencode", letter = "O", setting = "opencode_command", toggle = "show_opencode" },
}

local DEFAULTS = {
  command = "~/.local/bin/claude-usage",
  codex_command = "~/.local/bin/codex-usage",
  antigravity_command = "~/.local/bin/antigravity-usage",
  opencode_command = "~/.local/bin/opencode-usage",
  show_claude = true,
  show_codex = true,
  show_antigravity = true,
  show_opencode = true,
  show_spend = false,
  bar_style = "auto",
  compact_below = 1500,
  glyph = "gauge",
  warn_color = "#e0af68",
  refresh_seconds = 120,
  warn_at = 50,
  alert_at = 80,
}

function M.conf(key)
  local value = noctalia.getConfig(key)
  if value == nil or value == "" then return DEFAULTS[key] end
  return value
end

function M.enabled(provider)
  return M.conf(provider.toggle) and true or false
end

--------------------------------------------------------------------------------
-- Spelling
--------------------------------------------------------------------------------

function M.now()
  return os.time()
end

function M.pctText(pct)
  return `{math.floor((tonumber(pct) or 0) + 0.5)}%`
end

function M.duration(seconds)
  local s = math.max(0, math.floor(seconds))
  if s >= 86400 then return `{s // 86400}d{(s % 86400) // 3600}h` end
  if s >= 3600 then return `{s // 3600}h{string.format("%02d", (s % 3600) // 60)}m` end
  if s >= 60 then return `{s // 60}m` end
  return "<1m"
end

-- One unit is enough for "how long ago"; a countdown needs two.
function M.ago(epoch)
  local s = math.max(0, M.now() - epoch)
  if s < 60 then return noctalia.tr("just_now") end
  local text = s >= 86400 and `{s // 86400}d` or s >= 3600 and `{s // 3600}h` or `{s // 60}m`
  return noctalia.tr("ago", { time = text })
end

function M.clock(epoch)
  local today = os.date("%Y%m%d") == os.date("%Y%m%d", epoch)
  return noctalia.formatTime(today and "{:%H:%M}" or "{:%a %d, %H:%M}", epoch)
end

local function capitalise(text)
  return (text:gsub("^%l", string.upper))
end

--------------------------------------------------------------------------------
-- Colour
--------------------------------------------------------------------------------

-- Severity, as a colour for marks. Palette roles where a role carries the right
-- meaning ("error" is red in every theme, "primary" is the theme's own accent).
-- The middle band is a plain amber instead: the accent roles that would be free
-- to use there ("tertiary") are green in plenty of themes, which reads as fine
-- rather than as caution.
function M.colorFor(pct)
  local value = tonumber(pct) or 0
  if value >= (tonumber(M.conf("alert_at")) or DEFAULTS.alert_at) then return "error" end
  if value >= (tonumber(M.conf("warn_at")) or DEFAULTS.warn_at) then return M.conf("warn_color") end
  return "primary"
end

-- Severity, as a colour for text: plain ink until there is something to say, so
-- the number that needs attention is the only coloured one. The fixed amber is
-- too pale to read on a light surface, so there only its bar wears it.
function M.inkFor(pct)
  local color = M.colorFor(pct)
  if color == "primary" then return "on_surface" end
  if color ~= "error" and not noctalia.isDarkMode() then return "on_surface" end
  return color
end

-- A translucent version of a role ("primary") or of a "#rrggbb" literal.
function M.tint(color, alpha)
  if color:sub(1, 1) == "#" then
    return color:sub(1, 7) .. string.format("%02x", math.floor(alpha * 255 + 0.5))
  end
  return `{color:match("^[^/]+")}/{alpha}`
end

--------------------------------------------------------------------------------
-- Windows
--------------------------------------------------------------------------------

-- Every provider names its windows differently ("weekly", "1w", "5h"); they are
-- listed side by side, so they are spelled the same way here.
local SHORT = { session = "5h", weekly = "7d", ["1w"] = "7d", daily = "24h", ["1d"] = "24h" }

local function shortName(name)
  return SHORT[name] or name or "?"
end

local function longName(name)
  local short = shortName(name)
  local key = `window.{short}`
  local text = noctalia.tr(key)
  return text ~= key and text or short
end

-- Points of usage above or below an even burn before it is worth mentioning.
local PACE_SLACK = 10

local function windowRow(label, source, fullLabel)
  local row = {
    label = label,
    fullLabel = fullLabel or label,
    pct = tonumber(source.pct) or 0,
    left = source.left,
  }
  local resetsAt = tonumber(source.resets_at) or 0
  local length = (tonumber(source.minutes) or 0) * 60
  if resetsAt <= 0 then return row end

  local remaining = resetsAt - M.now()
  row.resetsAt = resetsAt
  row.remaining = remaining
  -- The window this reading describes is over, so its percentage says nothing
  -- about the one running now.
  row.expired = remaining <= 0
  row.left = row.expired and "" or M.duration(remaining)

  if length > 0 and not row.expired then
    local elapsed = math.clamp((length - remaining) / length, 0, 1)
    row.elapsed = elapsed
    row.ahead = row.pct - elapsed * 100 > PACE_SLACK
    -- Too early in a window a single burst projects absurdly, so wait for some
    -- of it to pass before predicting anything.
    if row.ahead and elapsed >= 0.05 and row.pct >= 10 and row.pct < 100 then
      local runsOutIn = elapsed * length * (100 - row.pct) / row.pct
      if runsOutIn < remaining then row.runsOutIn = runsOutIn end
    end
  end
  return row
end

--------------------------------------------------------------------------------
-- Providers
--------------------------------------------------------------------------------

local BUILDERS = {}

function BUILDERS.claude(data)
  local rows = {}
  if data.session then table.insert(rows, windowRow(longName("session"), data.session)) end
  if data.weekly then table.insert(rows, windowRow(longName("weekly"), data.weekly)) end
  local spend = data.spend or {}
  if M.conf("show_spend") and spend.enabled then
    table.insert(rows, {
      label = noctalia.tr("credits"),
      fullLabel = noctalia.tr("credits"),
      pct = tonumber(spend.pct) or 0,
      detail = `{spend.used or "?"} / {spend.limit or "?"}`,
    })
  end
  return { rows = rows }
end

function BUILDERS.codex(data)
  local rows = {}
  for _, entry in ipairs(data.windows or {}) do
    table.insert(rows, windowRow(longName(entry.name), entry))
  end
  local credits = data.credits or {}
  if credits.has_credits or credits.unlimited then
    table.insert(rows, {
      label = noctalia.tr("credits"),
      fullLabel = noctalia.tr("credits"),
      note = credits.unlimited and noctalia.tr("unlimited") or tostring(credits.balance or "?"),
    })
  end
  return { rows = rows }
end

function BUILDERS.antigravity(data)
  local rows = {}
  for _, group in ipairs(data.groups or {}) do
    local groupName = group.id == "third-party" and noctalia.tr("third_party") or group.label or group.short or "?"
    local scoped = {}
    for _, entry in ipairs(group.windows or {}) do
      -- "weekly" is the group's own quota; "argon-wtu-weekly" is one model's.
      local name = tostring(entry.name or "?")
      local scope, base = name:match("^(.+)%-(weekly)$")
      if not scope then scope, base = name:match("^(.+)%-(5h)$") end
      local short = shortName(base or name)
      local label = scope and `{capitalise(scope)} · {short}` or `{groupName} · {short}`
      local full = scope and `{groupName} {scope} · {short}` or label
      table.insert(scope and scoped or rows, windowRow(label, entry, full))
    end
    table.move(scoped, 1, #scoped, #rows + 1, rows)
  end
  return { rows = rows, model = (data.model or {}).display_name }
end

function BUILDERS.opencode(data)
  local rows = {}
  for _, entry in ipairs(data.windows or {}) do
    table.insert(rows, windowRow(longName(entry.name), entry))
  end
  return { rows = rows }
end

-- One entry per enabled provider, in a fixed order, whether or not it has data.
-- `worst` is the highest window still open, or nil when no reading applies.
function M.agents(snapshot)
  local data = (snapshot and snapshot.data) or {}
  local failure = (snapshot and snapshot.failure) or {}
  local list = {}
  for _, provider in ipairs(M.PROVIDERS) do
    if M.enabled(provider) then
      local source = data[provider.key]
      local agent = source and BUILDERS[provider.key](source) or { rows = {} }
      agent.key = provider.key
      agent.letter = provider.letter
      agent.name = noctalia.tr(`provider.{provider.key}`)
      agent.failure = failure[provider.key]
      agent.hasData = source ~= nil
      if source then
        agent.plan = source.plan and source.plan ~= "" and source.plan ~= "unknown" and capitalise(source.plan) or nil
        agent.stale = source.stale and true or false
        agent.staleReason = source.stale_reason
        agent.fetchedAt = tonumber(source.fetched_at)
      end

      local windows, open = 0, 0
      for _, row in ipairs(agent.rows) do
        if row.pct then
          windows += 1
          if not row.expired then
            open += 1
            if not agent.worst or row.pct > agent.worst then
              agent.worst = row.pct
              agent.worstRow = row
            end
            if row.runsOutIn and (not agent.urgent or row.runsOutIn < agent.urgent.runsOutIn) then
              agent.urgent = row
            end
          end
        end
      end
      agent.outdated = windows > 0 and open == 0
      -- At the limit the agent is already stopped; projecting another window is noise.
      if agent.worst and agent.worst >= 100 then agent.urgent = nil end
      table.insert(list, agent)
    end
  end
  return list
end

-- The agent closest to its limit, or nil when nothing is known yet.
function M.worstOf(list)
  local worst = nil
  for _, agent in ipairs(list) do
    if agent.worst and (not worst or agent.worst > worst.worst) then worst = agent end
  end
  return worst
end

-- Why an agent's numbers are not fresh, in words, or nil when they are.
function M.staleText(agent)
  if not agent.hasData then return nil end
  local when = agent.fetchedAt and agent.fetchedAt > 0 and M.ago(agent.fetchedAt) or "?"
  if agent.outdated then return noctalia.tr("outdated", { time = when }) end
  if not agent.stale and not agent.failure then return nil end
  local text = noctalia.tr("stale", { time = when })
  local reason = agent.failure
  if not reason and agent.staleReason and agent.staleReason ~= "" then
    reason = noctalia.tr(`stale_reason.{agent.staleReason}`)
  end
  return reason and `{text} · {reason}` or text
end

return M
