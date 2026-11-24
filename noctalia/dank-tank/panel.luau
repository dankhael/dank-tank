--!nonstrict
-- Detail panel: one card per agent with every window it reports. It only draws;
-- opening it asks the service for anything older than a few seconds.

local model = require("./lib/model.luau")

local snapshot = noctalia.state.get("snapshot")
local busy = noctalia.state.get("busy") and true or false
local open = false
local ticks = 0

-- Column widths shared by every row of every card, so the bars line up down the
-- whole panel. They sit on ui.row because ui.label ignores `width`.
local PCT_W, PACE_W, LEFT_W = 38, 12, 48
local LABEL_MIN, LABEL_MAX = 52, 104
local labelWidth = LABEL_MIN

-- As wide as the longest label on show needs: Antigravity names a group in every
-- row, but while it has nothing to show the bars can have that room.
local function measureLabels(list)
  local longest = 0
  for _, agent in ipairs(list) do
    if not agent.outdated then
      for _, row in ipairs(agent.rows) do
        longest = math.max(longest, utf8.len(row.label) or #row.label)
      end
    end
  end
  labelWidth = math.clamp(math.ceil(longest * 7), LABEL_MIN, LABEL_MAX)
end

-- ui.scroll insets its content by this much; the header and legend match it.
local EDGE = 4

local function cell(width, justify, child)
  return ui.row({ width = width, align = "center", justify = justify }, { child })
end

local function small(text, color, extra)
  local props = { text = text, fontSize = 11, color = color or "on_surface_variant" }
  for key, value in pairs(extra or {}) do props[key] = value end
  return ui.label(props)
end

local function rowTooltip(row)
  local parts = { `{row.fullLabel}: {model.pctText(row.pct)}` }
  if row.expired then
    table.insert(parts, noctalia.tr("tip.expired", { time = model.clock(row.resetsAt) }))
  else
    if row.elapsed then
      table.insert(parts, noctalia.tr("tip.elapsed", { pct = model.pctText(row.elapsed * 100) }))
    end
    if row.resetsAt then
      table.insert(parts, noctalia.tr("tip.resets", { time = model.clock(row.resetsAt) }))
    end
    if row.runsOutIn then
      table.insert(parts, noctalia.tr("tip.runs_out", { time = model.clock(model.now() + row.runsOutIn) }))
    end
  end
  return table.concat(parts, "\n")
end

local function windowRow(index, row)
  local key = `row-{index}`
  local label = cell(labelWidth, "start", ui.label({
    text = row.label,
    fontSize = 12,
    color = "on_surface_variant",
    maxWidth = labelWidth,
    maxLines = 1,
  }))

  -- A credits row may carry a balance instead of a percentage; it keeps the same
  -- label column so the cards still read as one table.
  if not row.pct then
    return ui.row({ key = key, gap = 8, align = "center" }, {
      label,
      ui.label({ text = row.note or "?", fontSize = 12, flexGrow = 1 }),
    })
  end

  if row.expired then
    return ui.row({ key = key, gap = 8, align = "center", opacity = 0.6, tooltip = rowTooltip(row) }, {
      label,
      ui.progress({ progress = 0, flexGrow = 1, height = 6, radius = 3, track = "on_surface/0.12" }),
      cell(PCT_W, "end", ui.label({ text = "–", fontSize = 12, color = "on_surface_variant" })),
      cell(PACE_W + LEFT_W + 8, "end", small(noctalia.tr("expired"))),
    })
  end

  local tail
  if row.detail then
    tail = { small(row.detail) }
  else
    tail = {
      cell(PACE_W, "center", small(row.ahead and "↑" or "", model.conf("warn_color"), { fontWeight = "bold" })),
      cell(LEFT_W, "end", small(row.left or "")),
    }
  end

  return ui.row({ key = key, gap = 8, align = "center", tooltip = rowTooltip(row) }, {
    label,
    ui.progress({
      progress = math.clamp(row.pct / 100, 0, 1),
      marker = row.elapsed,
      markerColor = "on_surface/0.55",
      flexGrow = 1,
      height = 6,
      radius = 3,
      fill = model.colorFor(row.pct),
      track = "on_surface/0.12",
    }),
    cell(PCT_W, "end", ui.label({
      text = model.pctText(row.pct),
      fontSize = 12,
      fontWeight = "bold",
      color = model.inkFor(row.pct),
    })),
    unpack(tail),
  })
end

-- The icon carries the severity; the words stay in plain ink so they read on any
-- theme.
local function note(key, glyph, color, text, ink)
  return ui.row({ key = key, gap = 6, align = "center" }, {
    ui.glyph({ name = glyph, size = 13, color = color }),
    ui.label({ text = text, fontSize = 11, color = ink or "on_surface", flexGrow = 1, maxLines = 2 }),
  })
end

local function badge(agent)
  return ui.row({ width = 24, height = 24, radius = 7, align = "center", justify = "center", fill = "on_surface/0.07" }, {
    ui.image({ path = model.logo(agent.key), width = 16, height = 16, fit = "contain" }),
  })
end

local function card(agent)
  local children = {
    ui.row({ key = "head", gap = 8, align = "center" }, {
      badge(agent),
      ui.label({ text = agent.name, fontSize = 14, fontWeight = "bold" }),
      small(agent.model or "", nil, { flexGrow = 1, maxLines = 1 }),
      small(agent.plan or ""),
    }),
  }

  -- Once every window has rolled over there is nothing left to measure; a wall
  -- of empty bars would only bury the agents that do have readings.
  if not agent.outdated then
    for index, row in ipairs(agent.rows) do
      table.insert(children, windowRow(index, row))
    end
  end

  local worst = agent.worstRow
  if worst and worst.pct >= 100 then
    local text = worst.left and worst.left ~= "" and noctalia.tr("limit_reached", { time = worst.left })
      or noctalia.tr("limit_reached_bare")
    table.insert(children, note("limit", "alert-triangle", "error", text))
  elseif agent.urgent then
    table.insert(children, note("urgent", "flame", model.conf("warn_color"), noctalia.tr("runs_out", {
      window = agent.urgent.label,
      time = model.duration(agent.urgent.runsOutIn),
    })))
  end

  if not agent.hasData then
    if agent.failure then
      table.insert(children, note("failure", "alert-triangle", "error", agent.failure))
    else
      table.insert(children, small(noctalia.tr("loading")))
    end
  else
    local stale = model.staleText(agent)
    if stale then
      local serious = agent.failure or agent.staleReason == "auth" or agent.staleReason == "login"
      table.insert(children, note(
        "stale",
        serious and "alert-triangle" or agent.outdated and "history" or "clock",
        serious and model.conf("warn_color") or "on_surface_variant",
        stale,
        not serious and "on_surface_variant" or nil
      ))
    end
  end

  return ui.column({
    key = agent.key,
    gap = 8,
    padding = 12,
    radius = 12,
    fill = "surface_container/0.55",
  }, children)
end

local function header(list)
  local worst = model.worstOf(list)
  local newest = nil
  for _, agent in ipairs(list) do
    if agent.fetchedAt and (not newest or agent.fetchedAt > newest) then newest = agent.fetchedAt end
  end
  local status = ""
  if busy then
    status = noctalia.tr("updating")
  elseif newest then
    status = noctalia.tr("updated", { time = model.clock(newest) })
  end

  return ui.row({ key = "header", gap = 8, align = "center", paddingH = EDGE }, {
    ui.glyph({
      name = model.conf("glyph"),
      size = 18,
      color = worst and model.colorFor(worst.worst) or "on_surface_variant",
    }),
    ui.label({ text = noctalia.tr("title"), fontSize = 15, fontWeight = "bold" }),
    small(status, nil, { flexGrow = 1, maxLines = 1 }),
    ui.button({
      key = "refresh",
      glyph = busy and "loader" or "refresh",
      glyphSize = 14,
      variant = "ghost",
      controlSize = "sm",
      enabled = not busy,
      tooltip = noctalia.tr("refresh"),
      onClick = "onRefresh",
    }),
    ui.button({
      key = "settings",
      glyph = "settings",
      glyphSize = 14,
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("open_settings"),
      onClick = "onSettings",
    }),
    ui.button({
      key = "close",
      glyph = "x",
      glyphSize = 14,
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("close"),
      onClick = "onCloseClicked",
    }),
  })
end

local function legend()
  return ui.row({ key = "legend", gap = 6, align = "center", paddingH = EDGE }, {
    ui.box({ width = 2, height = 10, radius = 1, fill = "on_surface/0.55" }),
    small(noctalia.tr("legend_pace")),
    ui.box({ width = 4, height = 1 }),
    small("↑", model.conf("warn_color"), { fontWeight = "bold" }),
    small(noctalia.tr("legend_ahead")),
  })
end

local function render()
  if not open then return end
  local list = model.agents(snapshot)
  measureLabels(list)
  local cards = {}
  local anyPace = false
  for _, agent in ipairs(list) do
    table.insert(cards, card(agent))
    for _, row in ipairs(agent.rows) do
      if row.elapsed then anyPace = true end
    end
  end
  if #cards == 0 then
    table.insert(cards, small(noctalia.tr("nothing_enabled")))
  end

  -- The panel follows this tree's height up to `max_height` in the manifest.
  -- Both flexGrow matter past that point: they hand the leftover space to the
  -- scroll area, so the header and the legend stay put and only the cards move.
  panel.render(ui.column({ gap = 6, flexGrow = 1 }, {
    header(list),
    ui.scroll({ key = "cards", gap = 8, flexGrow = 1 }, cards),
    anyPace and legend() or nil,
  }))
end

noctalia.state.watch("snapshot", function(value)
  snapshot = value
  render()
end)

noctalia.state.watch("busy", function(value)
  busy = value and true or false
  render()
end)

local function request(force, maxAge)
  noctalia.state.set("request", { at = noctalia.nowMs(), force = force, maxAge = maxAge })
end

function onOpen()
  open = true
  ticks = 0
  panel.setWantsSecondTicks(true)
  render()
  request(false, 30)
end

function onClose()
  open = false
end

-- Countdowns move by the minute; the host drops identical trees anyway.
function update()
  ticks += 1
  if ticks % 10 == 0 then render() end
end

function onRefresh()
  request(true)
end

function onSettings()
  noctalia.openSettings()
end

function onCloseClicked()
  panel.close()
end

function onKey(chord, pressed)
  if chord == "r" and pressed and not busy then request(true) end
end
