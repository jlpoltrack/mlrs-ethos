--[[
  Copyright (C) 2025 Rob Thomson
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
]]--

local SYSTEM_TOOL = false  -- set to true to force system tool registration

local BASE = "SCRIPTS:/mlrs"

local mlrs = assert(loadfile(BASE .. "/mlrs.lua"))()

------------------------------------------------------------
-- Singleton state (forms app is typically single-instance)
------------------------------------------------------------
local icon = lcd and lcd.loadMask and lcd.loadMask(BASE .. "/icon.png") or nil

local api
local requested = false
local loadedParams = false
local paramsRequested = false

local statusMsg = "Starting…"
local errMsg

local dev -- {tx=..., rx=..., info=...}
local info
local params

local bindActive = false
local bindEndAt = 0

local hasUnsavedChanges = false

local function now() return os.clock() end
local function fmt(x) return (x == nil) and "---" or tostring(x) end

------------------------------------------------------------
-- UI handles (keep widget refs, update in-place)
------------------------------------------------------------
local ui = {
  built = false,          -- structure built for params screen
  builtLoading = false,   -- structure built for loading screen

  status = nil,
  tx = nil,
  rx = nil,

  bindStatus = nil,
  bindButton = nil,       -- may or may not support in-place text; we use press fn gating

  saveHint = nil,
  saveButton = nil,

  param = {},             -- ui.param[idx0] = field handle
}

-- Structural rebuild flag (ONLY for structure changes)
local dirtyForm = true

local function safeCall(obj, method, ...)
  if not obj then return nil end
  local fn = obj[method]
  if type(fn) ~= "function" then return nil end
  return fn(obj, ...)
end

local function statusText()
  if errMsg and errMsg ~= "" then
    return "ERR: " .. errMsg
  end
  return statusMsg or ""
end

local function updateStatusWidgets()
  safeCall(ui.status, "value", statusText())
end

local function updateHeaderWidgets()
  local tx = dev and dev.tx
  local rx = dev and dev.rx

  if tx and tx.name then
    safeCall(ui.tx, "value", fmt(tx.name) .. " " .. fmt(tx.version_str))
  else
    safeCall(ui.tx, "value", "")
  end

  if rx and rx.name then
    safeCall(ui.rx, "value", fmt(rx.name) .. " " .. fmt(rx.version_str))
  else
    safeCall(ui.rx, "value", "")
  end
end

local function setStatus(s)
  statusMsg = s or ""
  -- No rebuild needed; update in-place if possible
  updateStatusWidgets()
end

local function setErr(s)
  errMsg = s
  updateStatusWidgets()
end

------------------------------------------------------------
-- UI helpers
------------------------------------------------------------
local function buildChoicesFromOptions(opts)
  local choices = {}
  opts = opts or {}
  for i = 1, #opts do
    local label = tostring(opts[i] or "")
    if label ~= "-" and label ~= "" then
      -- Ethos choice tables are usually { {label, value}, ... }
      choices[#choices + 1] = { label, i - 1 } -- 0-based values
    end
  end
  if #choices == 0 then
    choices = { { "-", 0 } }
  end
  return choices
end

local function sanitizeBindPhrase(s)
  s = tostring(s or "")
  s = string.lower(s)
  s = s:gsub("[^a-z0-9_#%-%.-]", "_")
  if #s > 6 then
    s = s:sub(1, 6)
  elseif #s < 6 then
    s = s .. string.rep("_", 6 - #s)
  end
  return s
end

------------------------------------------------------------
-- Bind helpers
------------------------------------------------------------
local function doBindStart()
  if not api then return end
  setErr(nil)
  setStatus("Starting bind…")
  api:bindStart(function(res)
    if not res.ok then
      setErr("BindStart: " .. fmt(res.err))
      setStatus("Error")
      return
    end
    bindActive = true
    bindEndAt = now() + 20.0
    setStatus("Bind mode (20s)…")
    -- No structural change required; we just update the bind status line
  end)
end

local function doBindStop()
  if not api then return end
  setErr(nil)
  setStatus("Stopping bind…")
  api:bindStop(function(res)
    if not res.ok then
      setErr("BindStop: " .. fmt(res.err))
      setStatus("Error")
      return
    end
    bindActive = false
    bindEndAt = 0
    setStatus("Bind stopped")
  end)
end

local function updateBindWidgets()
  if not ui.bindStatus then return end

  if bindActive then
    local left = math.max(0, bindEndAt - now())
    safeCall(ui.bindStatus, "value", "ACTIVE (auto-stop in " .. string.format("%.0f", left) .. "s)")
  else
    safeCall(ui.bindStatus, "value", "Idle")
  end
end

------------------------------------------------------------
-- MLRS request chain
------------------------------------------------------------
local function requestBasics()
  if requested or not api then return end
  requested = true
  setStatus("Requesting device items…")

  api:getDeviceItems(function(res)
    if not res.ok then
      setErr("DeviceItems: " .. fmt(res.err))
      setStatus("Error")
      return
    end
    dev = res.data
    if dev and dev.info then info = dev.info end

    setStatus("Requesting INFO…")
    api:getInfo(function(res2)
      if not res2.ok then
        setErr("Info: " .. fmt(res2.err))
        setStatus("Error")
        return
      end
      info = res2.data and res2.data.info or info
      setStatus("Ready")

      -- Update header in-place if form already exists
      updateHeaderWidgets()
    end)
  end)
end

local function requestAllParams()
  if not api then return end
  setStatus("Loading params…")
  setErr(nil)

  api:getAllParams(function(res)
    if not res.ok then
      setErr("Params: " .. fmt(res.err))
      setStatus("Error")
      return
    end
    params = res.data and res.data.params or nil
    loadedParams = true
    hasUnsavedChanges = false
    setStatus("Params loaded")

    -- Structural transition: loading screen -> params screen
    dirtyForm = true
  end, { full = true, deadlineS = 30.0 })
end

------------------------------------------------------------
-- Param field updates (in-place)
------------------------------------------------------------
local function updateSaveWidgets()
  if not ui.saveHint then return end
  if hasUnsavedChanges then
    safeCall(ui.saveHint, "value", "Pending changes")
  else
    safeCall(ui.saveHint, "value", "No pending changes")
  end
end

local function updateParamWidget(p)
  if not p then return end
  local f = ui.param[p.idx0]
  if not f then return end

  -- value
  safeCall(f, "value", p.value)

  -- type-specific metadata
  if p.typ == 4 then
    -- LIST choices
    local choices = buildChoicesFromOptions(p.options)
    safeCall(f, "values", choices)
    -- Some firmwares expose min/max too; harmless if absent
    safeCall(f, "minimum", 0)
    safeCall(f, "maximum", math.max(#choices - 1, 0))
  elseif p.typ ~= 5 then
    -- numeric
    if p.min ~= nil then safeCall(f, "minimum", p.min) end
    if p.max ~= nil then safeCall(f, "maximum", p.max) end
  end
end

local function commitParam(p, newValue)
  if not api or not p then return end
  setErr(nil)
  setStatus("Setting " .. fmt(p.name) .. "…")

  api:setParam(p.idx0, newValue, function(res)
    if not res.ok then
      setErr("Set: " .. fmt(res.err))
      setStatus("Error")
      return
    end

    -- update model
    p.value = newValue
    hasUnsavedChanges = true

    -- update UI in-place (no rebuild)
    updateParamWidget(p)
    updateSaveWidgets()

    setStatus("Ready")
  end)
end

------------------------------------------------------------
-- Actions
------------------------------------------------------------
local function doSave()
  if not api then return end
  if not hasUnsavedChanges then
    setStatus("No pending changes")
    return
  end
  setErr(nil)
  setStatus("Saving…")

  api:store(function(res)
    if not res.ok then
      setErr("Store: " .. fmt(res.err))
      setStatus("Error")
      return
    end
    hasUnsavedChanges = false
    updateSaveWidgets()
    setStatus("Saved")
  end)
end

local function doReload()
  if not api then return end
  api:reset()

  requested = false
  loadedParams = false
  paramsRequested = false
  hasUnsavedChanges = false

  dev, info, params = nil, nil, nil
  errMsg = nil
  statusMsg = "Reloading…"
  bindActive = false
  bindEndAt = 0

  -- force structural rebuild back to loading view
  ui.built = false
  ui.builtLoading = false
  ui.param = {}
  ui.status, ui.tx, ui.rx = nil, nil, nil
  ui.bindStatus, ui.bindButton = nil, nil
  ui.saveHint, ui.saveButton = nil, nil
  dirtyForm = true

  requestBasics()
end

------------------------------------------------------------
-- Form building (structure)
------------------------------------------------------------
local function addButtonLine(label, buttonText, pressFn)
  local line = form.addLine(label or "")
  if form.addButton then
    return form.addButton(line, nil, { text = buttonText, press = pressFn })
  end
  return form.addTextButton(line, nil, buttonText, pressFn)
end

local function buildLoadingForm()
  form.clear()
  ui.param = {}

  local line = form.addLine("Status")
  ui.status = form.addStaticText(line, nil, statusText())

  local l2 = form.addLine("")
  form.addStaticText(l2, nil, "Loading parameters…")

  local l3 = form.addLine("")
  addButtonLine("", "Reload", doReload)

  ui.builtLoading = true
  ui.built = false

  updateHeaderWidgets()
  updateBindWidgets()
  updateSaveWidgets()
end

local function buildParamsForm()
  form.clear()
  ui.param = {}

  -- Status
  do
    local line = form.addLine("Status")
    ui.status = form.addStaticText(line, nil, statusText())
  end

  -- TX / RX identity
  do
    local line = form.addLine("TX")
    ui.tx = form.addStaticText(line, nil, "")
    local line2 = form.addLine("RX")
    ui.rx = form.addStaticText(line2, nil, "")
  end

  -- Bind section (status + one button; press fn decides action)
  do
    local line = form.addLine("Bind")
    ui.bindStatus = form.addStaticText(line, nil, "")
    addButtonLine("", "Bind / Stop", function()
      if bindActive then doBindStop() else doBindStart() end
    end)
  end

  -- Params
  if params then
    for i = 1, #params do
      local p = params[i]
      if p and p.name and p.name ~= "" then
        local label = p.name
        if p.unit and p.unit ~= "" then
          label = label .. " (" .. p.unit .. ")"
        end

        local editable = (p.editable ~= false)
        if editable then
          local line = form.addLine(label)

          if p.typ == 4 then
            -- LIST
            local choices = buildChoicesFromOptions(p.options)
            local getter = function()
              local v = tonumber(p.value) or 0
              if v < 0 then v = 0 end
              if v > (#choices - 1) then v = (#choices - 1) end
              return v
            end
            local setter = function(val)
              commitParam(p, tonumber(val) or 0)
            end

            local f = form.addChoiceField(line, nil, choices, getter, setter)
            ui.param[p.idx0] = f

            -- set metadata via methods if available
            safeCall(f, "values", choices)
            safeCall(f, "minimum", 0)
            safeCall(f, "maximum", math.max(#choices - 1, 0))

          elseif p.typ == 5 then
            -- STR6
            local getter = function()
              return sanitizeBindPhrase(p.value)
            end
            local setter = function(newValue)
              commitParam(p, sanitizeBindPhrase(newValue))
            end

            local f = form.addTextField(line, nil, getter, setter)
            ui.param[p.idx0] = f

          else
            -- numeric
            local min = p.min or 0
            local max = p.max or 65535
            local getter = function() return p.value or 0 end
            local setter = function(val) commitParam(p, val) end

            local f = form.addNumberField(line, nil, min, max, getter, setter)
            ui.param[p.idx0] = f

            safeCall(f, "minimum", min)
            safeCall(f, "maximum", max)
          end
        end
      end
    end
  end

  -- Save / Reload footer
  do
    local line = form.addLine("Save")
    ui.saveHint = form.addStaticText(line, nil, "")
    ui.saveButton = addButtonLine("", "Save Params", doSave)
    addButtonLine("", "Reload", doReload)
  end

  ui.built = true
  ui.builtLoading = false

  -- Push initial values in-place
  updateHeaderWidgets()
  updateBindWidgets()
  updateSaveWidgets()

  if params then
    for i = 1, #params do
      local p = params[i]
      updateParamWidget(p)
    end
  end
end

local function ensureForm()
  if not dirtyForm then return end
  dirtyForm = false

  if loadedParams and params then
    buildParamsForm()
  else
    buildLoadingForm()
  end
end

------------------------------------------------------------
-- Tool / module lifecycle
------------------------------------------------------------
local function create()
  if not api then
    api = mlrs.new({ settleS = 1.5, strategy = "by_index", saveDeadS = 3.0 })
    setmetatable(api, { __index = mlrs })
  end

  requested = false
  loadedParams = false
  paramsRequested = false
  hasUnsavedChanges = false

  dev, info, params = nil, nil, nil
  errMsg = nil
  statusMsg = "Starting…"
  bindActive = false
  bindEndAt = 0

  ui.built = false
  ui.builtLoading = false
  ui.param = {}
  ui.status, ui.tx, ui.rx = nil, nil, nil
  ui.bindStatus, ui.bindButton = nil, nil
  ui.saveHint, ui.saveButton = nil, nil

  dirtyForm = true

  requestBasics()
  ensureForm()
  return {}
end

local function wakeup(_)
  if not api then return end
  api:processQueue(24)

  -- Build structure if needed
  ensureForm()

  -- auto-stop bind after timeout
  if bindActive and bindEndAt and now() >= bindEndAt then
    doBindStop()
  end

  -- Start param load exactly once after basics are ready
  if requested and not paramsRequested and not loadedParams and not errMsg and statusMsg == "Ready" then
    paramsRequested = true
    requestAllParams()
    bindActive = false
    bindEndAt = 0
  end

  -- In-place “dynamic” UI updates (no rebuild)
  updateStatusWidgets()
  updateHeaderWidgets()
  updateBindWidgets()
  updateSaveWidgets()
end

local function event(_) end
local function paint(_) end

local function close(_)
  if api and api.reset then
    api:reset()
  end

  requested = false
  loadedParams = false
  paramsRequested = false
  hasUnsavedChanges = false

  dev, info, params = nil, nil, nil
  errMsg = nil
  statusMsg = "Closed"
  bindActive = false
  bindEndAt = 0

  api = nil
  collectgarbage("collect")
end

local function init()

  -- force loading as system tool
  if SYSTEM_TOOL == true then
    print("MLRS: registering as system tool")
    system.registerSystemTool({
      name = "MLRS", icon = icon, create = create, wakeup = wakeup, event = event, paint = paint, close = close
    })
    return
  end

  -- otherwise, try to register as MLRS module if supported
  local v = system.getVersion()
  if v.major >= 1 and v.minor >= 7 and system.registerMlrsModule then
    print("MLRS: registering as MLRS module")
    system.registerMlrsModule({
      configure = { name = "MLRS", create = create, wakeup = wakeup, event = event, close = close }
    })
  else
    print("MLRS: registering as system tool")
    system.registerSystemTool({
      name = "MLRS", icon = icon, create = create, wakeup = wakeup, event = event, paint = paint, close = close
    })
  end
end

return { init = init }
