--!nonstrict
-- dank-tank: Claude, Codex, Antigravity and OpenCode Go plan usage in the noctalia bar.
--
-- One script backs two entries: the `usage` bar widget and the `detail` panel it
-- toggles. Each entry runs in its own VM and only ever calls its own entry point
-- (`update` for the widget, `onOpen` for the panel), so the polling and the
-- normalisation below are written once and the two renderers differ only in how
-- they draw the same agent list. (A shared module would be tidier, but
-- `require()` needs plugin API 22 and this shell caps at 20.)
--
-- The bar carries one number per agent - the worst window that agent has open -
-- because four agents times three or four windows is unreadable at a glance. The whole
-- breakdown lives one click away in the panel.
--
-- Each provider is polled independently. A failure on one side never hides a
-- good reading from another, and every command keeps its own 60s cache.

local PANEL = "dankhael/dank-tank:detail"

local DEFAULTS = {
  command = "~/.local/bin/claude-usage",
  codex_command = "~/.local/bin/codex-usage",
  antigravity_command = "~/.local/bin/antigravity-usage",
  opencode_command = "~/.local/bin/opencode-usage",
  show_codex = true,
  show_antigravity = true,
  show_opencode = true,
  show_spend = false,
  glyph = "gauge",
  warn_color = "#e0af68",
  refresh_seconds = 60,
  warn_at = 50,
  alert_at = 80,
}

local PROVIDERS = {
  {
    key = "claude",
    setting = "command",
    failed = "error.failed",
    unreadable = "error.bad_output",
  },
  {
    key = "codex",
    setting = "codex_command",
    toggle = "show_codex",
    failed = "error.codex_failed",
    unreadable = "error.codex_bad_output",
  },
  {
    key = "antigravity",
    setting = "antigravity_command",
    toggle = "show_antigravity",
    failed = "error.antigravity_failed",
    unreadable = "error.antigravity_bad_output",
  },
  {
    key = "opencode",
    setting = "opencode_command",
    toggle = "show_opencode",
    failed = "error.opencode_failed",
    unreadable = "error.opencode_bad_output",
  },
}

local LETTERS = { claude = "C", codex = "X", antigravity = "A", opencode = "O" }

local state = {
  data = {},
  failure = {},
  busy = {},
}

-- Which entry this VM is serving. Both entries run the same script and both see
-- the `barWidget` and `panel` namespaces, so the host's own callbacks decide:
-- only a panel VM ever gets `onOpen`, and a tick that arrives there must not
-- repaint the surface with the bar tree.
local surface = "bar"

local function conf(key)
  local value = noctalia.getConfig(key)
  if value == nil or value == "" then return DEFAULTS[key] end
  return value
end

local function resolve(path)
  if type(path) ~= "string" or path == "" then return "" end
  if path:sub(1, 2) == "~/" then
    local home = (noctalia.getenv and noctalia.getenv("HOME")) or ""
    if home ~= "" then return home .. path:sub(2) end
  end
  return path
end

local function enabled(provider)
  if not provider.toggle then return true end
  return conf(provider.toggle) and true or false
end

-- Polls every enabled provider. `onChange` fires once per finished provider, so
-- the first reading paints as soon as it lands instead of waiting on the slowest.
local function poll(force, onChange)
  for _, provider in ipairs(PROVIDERS) do
    if enabled(provider) and not state.busy[provider.key] then
      local bin = resolve(conf(provider.setting))
      if bin == "" then
        state.failure[provider.key] = noctalia.tr("error.no_command")
        onChange()
      else
        state.busy[provider.key] = true
        local cmd = `'{bin}' --bar-json` .. (force and " --refresh" or "")
        noctalia.runAsync(cmd, function(res)
          state.busy[provider.key] = false
          if not res or res.exitCode ~= 0 then
            state.failure[provider.key] = noctalia.tr(provider.failed)
          else
            local ok, data = pcall(noctalia.json.decode, res.stdout)
            if not ok or type(data) ~= "table" then
              state.failure[provider.key] = noctalia.tr(provider.unreadable)
            else
              state.data[provider.key] = data
              state.failure[provider.key] = nil
            end
          end
          onChange()
        end)
      end
    end
  end
end

local function pctText(pct)
  return `{math.floor((tonumber(pct) or 0) + 0.5)}%`
end

-- Palette roles where a role carries the right meaning ("error" is red in every
-- theme, "primary" is the theme's own accent). The middle band is a plain amber
-- instead: the accent roles that would be free to use here ("tertiary") are green
-- in plenty of themes, which reads as fine rather than as caution.
local function colorFor(pct)
  local value = tonumber(pct) or 0
  if value >= (tonumber(conf("alert_at")) or DEFAULTS.alert_at) then return "error" end
  if value >= (tonumber(conf("warn_at")) or DEFAULTS.warn_at) then return conf("warn_color") end
  return "primary"
end

-- Every provider names its windows differently ("weekly", "1w", "5h"); the panel
-- lists them side by side, so they are spelled the same way here.
local WINDOW_NAMES = {
  weekly = "7d",
  ["1w"] = "7d",
  daily = "24h",
  ["1d"] = "24h",
}

local function windowName(name)
  return WINDOW_NAMES[name] or name or "?"
end

local function windowRow(label, source)
  return {
    label = label,
    pct = tonumber(source.pct) or 0,
    pace = source.pace,
    left = source.left,
  }
end

local function claudeAgent()
  local data = state.data.claude
  if not data then return nil end

  local rows = {
    windowRow(noctalia.tr("session"), data.session or {}),
    windowRow(noctalia.tr("weekly"), data.weekly or {}),
  }
  local spend = data.spend or {}
  if conf("show_spend") and spend.enabled then
    table.insert(rows, {
      label = noctalia.tr("credits"),
      pct = tonumber(spend.pct) or 0,
      note = `{spend.used or "?"} / {spend.limit or "?"}`,
    })
  end
  return { rows = rows, stale = data.stale }
end

local function codexAgent()
  local data = state.data.codex
  if not data then return nil end

  local rows = {}
  for _, entry in ipairs(data.windows or {}) do
    table.insert(rows, windowRow(windowName(entry.name), entry))
  end
  local credits = data.credits or {}
  if credits.has_credits or credits.unlimited then
    table.insert(rows, {
      label = noctalia.tr("credits"),
      note = credits.unlimited and noctalia.tr("unlimited") or (credits.balance or "?"),
    })
  end
  return { rows = rows, plan = data.plan, stale = data.stale }
end

local function antigravityAgent()
  local data = state.data.antigravity
  if not data then return nil end

  local rows = {}
  for _, group in ipairs(data.groups or {}) do
    for _, entry in ipairs(group.windows or {}) do
      table.insert(rows, windowRow(`{group.label or group.short or "?"} {windowName(entry.name)}`, entry))
    end
  end
  local model = data.model or {}
  return { rows = rows, plan = data.plan, model = model.display_name, stale = data.stale }
end

-- OpenCode Go reports 5-hour, weekly and monthly windows as plain percentages;
-- there is no dollar figure to show, so each row is just the bar and countdown.
local function opencodeAgent()
  local data = state.data.opencode
  if not data then return nil end

  local rows = {}
  for _, entry in ipairs(data.windows or {}) do
    table.insert(rows, windowRow(windowName(entry.name), entry))
  end
  return { rows = rows, plan = data.plan, stale = data.stale }
end

local BUILDERS = {
  claude = claudeAgent,
  codex = codexAgent,
  antigravity = antigravityAgent,
  opencode = opencodeAgent,
}

-- One entry per enabled provider, in a fixed order, whether or not it has data.
-- An agent that failed carries `failure` and no rows; each renderer decides how
-- loud that should be.
local function agents()
  local list = {}
  for _, provider in ipairs(PROVIDERS) do
    if enabled(provider) then
      local built = BUILDERS[provider.key]()
      local agent = built or {}
      agent.key = provider.key
      agent.letter = LETTERS[provider.key]
      agent.name = noctalia.tr(provider.key)
      agent.rows = agent.rows or {}
      agent.failure = state.failure[provider.key]
      agent.hasData = built ~= nil

      local worst = 0
      for _, row in ipairs(agent.rows) do
        if row.pct then worst = math.max(worst, row.pct) end
      end
      agent.worst = worst

      table.insert(list, agent)
    end
  end
  return list
end

local function worstOf(list)
  local worst = 0
  for _, agent in ipairs(list) do
    worst = math.max(worst, agent.worst or 0)
  end
  return worst
end

local function anyData()
  return next(state.data) ~= nil
end

local function anyFailure()
  return next(state.failure) ~= nil
end

--------------------------------------------------------------------------------
-- Bar widget
--------------------------------------------------------------------------------

local function divider(vertical)
  -- A drawn hairline rather than ui.separator: the capsule clips to the bar
  -- thickness, and a fixed box keeps the rule the same size on every theme.
  if vertical then
    return ui.box({ width = 14, height = 1, fill = "on_surface/0.25" })
  end
  return ui.box({ width = 1, height = 12, fill = "on_surface/0.25" })
end

local function chip(agent)
  local text = agent.hasData and pctText(agent.worst) or "—"
  local color = agent.hasData and colorFor(agent.worst) or "on_surface_variant"
  if agent.failure then color = "error" end

  return ui.row({ key = agent.key, gap = 3, align = "center" }, {
    ui.label({ text = agent.letter, color = "on_surface_variant" }),
    ui.label({ text = text, color = color, fontWeight = "bold" }),
  })
end

local function tooltipText(list)
  local lines = { noctalia.tr("title") }
  local parts = {}
  for _, agent in ipairs(list) do
    if agent.failure then
      table.insert(parts, `{agent.name} —`)
    elseif agent.hasData then
      local mark = agent.stale and " *" or ""
      table.insert(parts, `{agent.name} {pctText(agent.worst)}{mark}`)
    end
  end
  if #parts > 0 then table.insert(lines, table.concat(parts, "  ·  ")) end
  for _, agent in ipairs(list) do
    if agent.failure then table.insert(lines, `{agent.name}: {agent.failure}`) end
  end
  table.insert(lines, noctalia.tr("hint"))
  return table.concat(lines, "\n")
end

local function renderBar()
  local vertical = barWidget.isVertical and barWidget.isVertical() or false
  local container = vertical and ui.column or ui.row
  local list = agents()

  if not anyData() then
    local waiting = not anyFailure()
    barWidget.render(container({ gap = 5, align = "center" }, {
      ui.glyph({ name = conf("glyph"), size = 14, color = waiting and "on_surface_variant" or "error" }),
      ui.label({ text = waiting and "…" or "—", color = "on_surface_variant" }),
    }))
    barWidget.setTooltip(waiting and noctalia.tr("title") or tooltipText(list))
    return
  end

  local items = {
    ui.glyph({ name = conf("glyph"), size = 14, color = colorFor(worstOf(list)) }),
  }
  for _, agent in ipairs(list) do
    if #items > 1 then table.insert(items, divider(vertical)) end
    table.insert(items, chip(agent))
  end

  barWidget.render(container({ gap = 7, align = "center" }, items))
  barWidget.setTooltip(tooltipText(list))
end

--------------------------------------------------------------------------------
-- Detail panel
--------------------------------------------------------------------------------

local LABEL_WIDTH = 116

local function panelRow(row)
  -- A credits row carries a balance instead of a percentage; it keeps the same
  -- label column so the cards still read as one table.
  if not row.pct then
    return ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = row.label, width = LABEL_WIDTH, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
      ui.label({ text = row.note or "?", fontSize = 12, flexGrow = 1 }),
    })
  end

  local color = colorFor(row.pct)
  return ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = row.label, width = LABEL_WIDTH, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    ui.progress({
      progress = math.min(math.max(row.pct / 100, 0), 1),
      flexGrow = 1,
      height = 6,
      radius = 3,
      fill = color,
      track = "on_surface/0.12",
    }),
    ui.label({ text = pctText(row.pct), width = 40, textAlign = "end", fontSize = 12, fontWeight = "bold", color = color }),
    ui.label({ text = row.pace or "", width = 10, fontSize = 12, color = "on_surface_variant" }),
    ui.label({ text = row.note or row.left or "", width = 54, textAlign = "end", fontSize = 11, color = "on_surface_variant" }),
  })
end

local function card(agent)
  local color = agent.failure and "error" or (agent.hasData and colorFor(agent.worst) or "on_surface_variant")
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.box({ width = 8, height = 8, radius = 4, fill = color }),
      ui.label({ text = agent.name, fontSize = 14, fontWeight = "bold" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        text = agent.plan and `{noctalia.tr("plan")} {agent.plan}` or "",
        fontSize = 11,
        color = "on_surface_variant",
      }),
    }),
  }

  if agent.model then
    table.insert(children, ui.label({ text = agent.model, fontSize = 11, color = "on_surface_variant" }))
  end
  for _, row in ipairs(agent.rows) do
    table.insert(children, panelRow(row))
  end
  if agent.failure then
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 12, color = "error" }),
      ui.label({ text = agent.failure, fontSize = 11, color = "error" }),
    }))
  elseif agent.stale then
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "clock", size = 12, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("stale"), fontSize = 11, color = "on_surface_variant" }),
    }))
  end

  return ui.column({
    key = agent.key,
    gap = 7,
    padding = 12,
    radius = 12,
    fill = "surface_variant/0.35",
  }, children)
end

local function renderPanel()
  local list = agents()
  local cards = {}
  for _, agent in ipairs(list) do
    table.insert(cards, card(agent))
  end

  panel.render(ui.column({ gap = 12, padding = 14 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = conf("glyph"), size = 16, color = colorFor(worstOf(list)) }),
      ui.label({ text = noctalia.tr("title"), fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", glyphSize = 14, variant = "ghost", tooltip = noctalia.tr("refresh"), onClick = "onRefresh" }),
      ui.button({ glyph = "x", glyphSize = 14, variant = "ghost", onClick = "onCloseClicked" }),
    }),
    -- An explicit height, not flexGrow: the panel surface is host-owned and the
    -- root column does not stretch to it, so a growing scroll area collapses to
    -- its intrinsic size. Keep this in step with `height` on the [[panel]] entry.
    ui.scroll({ gap = 10, height = 485 }, cards),
    ui.label({ text = noctalia.tr("pace_legend"), fontSize = 11, color = "on_surface_variant" }),
  }))
end

--------------------------------------------------------------------------------
-- Entry points
--------------------------------------------------------------------------------

-- Every poll finishes through here, so a reading that lands after the panel
-- opened never repaints the panel with the bar tree (or the other way round).
local function render()
  if surface == "panel" then
    renderPanel()
  else
    renderBar()
  end
end

function update()
  if surface == "panel" then
    render()
    return
  end
  local seconds = tonumber(conf("refresh_seconds")) or DEFAULTS.refresh_seconds
  if seconds < 15 then seconds = 15 end
  noctalia.setUpdateInterval(seconds * 1000)
  poll(false, render)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL)
end

-- The panel has its own refresh button; keeping a forced re-read on right-click
-- means the bar alone is still enough when you only want fresh numbers.
function onRightClick()
  poll(true, render)
end

function onOpen()
  surface = "panel"
  render()
  poll(false, render)
end

function onRefresh()
  poll(true, render)
end

function onCloseClicked()
  panel.close()
end
