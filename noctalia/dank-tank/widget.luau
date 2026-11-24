--!nonstrict
-- Bar widget: one number per agent, the window closest to its limit. It only
-- draws; readings come from the service through `noctalia.state`.

local model = require("./lib/model.luau")

local snapshot = noctalia.state.get("snapshot")

-- Where this instance lives. The host only fills these in for its own events
-- (load, update, clicks): inside a state callback `outputName()` is nil and
-- `isVertical()` is always false, so they are remembered rather than asked.
local vertical = false
local outputName = nil

local function locate()
  local name = barWidget.outputName()
  if not name then return end
  outputName = name
  vertical = barWidget.isVertical()
end

-- "auto" follows the monitor the bar is on: a portrait or small screen has no
-- room for the full row next to the clock and the tray.
local function style()
  local chosen = model.conf("bar_style")
  if chosen ~= "auto" then return chosen end
  for _, output in ipairs(noctalia.outputs()) do
    if output.name == outputName then
      local limit = tonumber(model.conf("compact_below")) or 1500
      return output.width < limit and "compact" or "full"
    end
  end
  return "full"
end

local function divider()
  -- A drawn hairline rather than ui.separator: the capsule clips to the bar
  -- thickness, and a fixed box keeps the rule the same size on every theme.
  return ui.box({ width = 1, height = 12, fill = "on_surface/0.2" })
end

local function icon(list)
  local worst = model.worstOf(list)
  local color = worst and model.colorFor(worst.worst) or "on_surface_variant"
  return ui.glyph({ key = "icon", name = model.conf("glyph"), size = 14, color = color })
end

-- What the chip says, and whether it deserves full strength. A dash means there
-- is no reading that applies right now, which is not the same as 0%.
local function reading(agent, suffix)
  if not agent.worst then
    return "–", agent.failure and "error" or "on_surface_variant", 0.7
  end
  local text = tostring(math.floor(agent.worst + 0.5)) .. suffix
  return text, model.inkFor(agent.worst), agent.stale and 0.65 or 1
end

local function chip(agent, suffix)
  local text, color, opacity = reading(agent, suffix)
  local letter = ui.label({ text = agent.letter, color = "on_surface_variant", fontSize = vertical and 10 or nil })
  local value = ui.label({ text = text, color = color, fontWeight = "bold", fontSize = vertical and 11 or nil })
  if vertical then
    return ui.column({ key = agent.key, gap = 0, align = "center", opacity = opacity }, { letter, value })
  end
  return ui.row({ key = agent.key, gap = suffix == "" and 2 or 3, align = "center", opacity = opacity }, { letter, value })
end

local function tooltip(list)
  local rows = {}
  for _, agent in ipairs(list) do
    local value
    if agent.worst then
      local row = agent.worstRow
      value = `{model.pctText(agent.worst)} · {row.label}`
      if row.left and row.left ~= "" then value ..= ` · {row.left}` end
      if agent.stale or agent.failure then value ..= " *" end
    else
      -- The host truncates long values here; the panel has the full story.
      value = noctalia.tr(agent.failure and "tip.unavailable" or agent.outdated and "tip.outdated" or "loading")
    end
    table.insert(rows, { key = agent.name, value = value })
  end
  local urgent = nil
  for _, agent in ipairs(list) do
    if agent.urgent and (not urgent or agent.urgent.runsOutIn < urgent.urgent.runsOutIn) then urgent = agent end
  end
  if urgent then
    table.insert(rows, {
      key = noctalia.tr("runs_out_key"),
      value = `{model.duration(urgent.urgent.runsOutIn)} · {urgent.name}`,
    })
  end
  return rows
end

local function render()
  local list = model.agents(snapshot)
  local mode = style()
  local items = {}

  if #list == 0 then
    items = { ui.glyph({ key = "icon", name = model.conf("glyph"), size = 14, color = "on_surface_variant" }) }
  elseif mode == "minimal" then
    local worst = model.worstOf(list)
    items = { icon(list), worst and chip(worst, vertical and "" or "%") or nil }
  elseif vertical then
    items = { icon(list) }
    for _, agent in ipairs(list) do table.insert(items, chip(agent, "")) end
  elseif mode == "compact" then
    for _, agent in ipairs(list) do table.insert(items, chip(agent, "")) end
  else
    items = { icon(list) }
    for index, agent in ipairs(list) do
      if index > 1 then table.insert(items, divider()) end
      table.insert(items, chip(agent, "%"))
    end
  end

  local container = vertical and ui.column or ui.row
  barWidget.render(container({ gap = vertical and 5 or 7, align = "center" }, items))
  barWidget.setTooltip(tooltip(list))
end

noctalia.state.watch("snapshot", function(value)
  snapshot = value
  render()
end)

-- Readings arrive through the watch; this only keeps countdowns and rolled-over
-- windows honest between them.
function update()
  noctalia.setUpdateInterval(60000)
  locate()
  render()
end

function onClick()
  noctalia.togglePanel(model.PANEL)
end

function onRightClick()
  noctalia.state.set("request", { at = noctalia.nowMs(), force = true })
end

locate()
render()
