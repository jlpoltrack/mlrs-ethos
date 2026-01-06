--[[
  Copyright (C) 2026 Rob Thomson
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html

  Date: 2026-01-02
]]--

local BASE = "RADIO:/scripts/mlrs"

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
local lastStatusText = ""
local errMsg

local dev -- {tx=..., rx=..., info=...}
local info
local params

local bindActive = false
local bindEndAt = 0

local hasUnsavedChanges = false
local lastRxAvailable = nil  -- track RX connection state changes
local lastInfoPollAt = 0     -- for periodic INFO refresh

local function now() return os.clock() end
local function fmt(x) return (x == nil) and "---" or tostring(x) end

-- Dirty flags for UI optimization
local dirtyHeader = false
local dirtyBind = false
local dirtySave = false

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

-- Cached widget values to avoid redundant calls to safeCall(..., "value", ...)
local ui_cache = {
  status = "",
  tx = "",
  rx = "",
  bindStatus = "",
  saveHint = "",
}

-- Structural rebuild flag (ONLY for structure changes)
local dirtyForm = true

local function safeCall(obj, method, ...)
  if not obj then return nil end
  local fn = obj[method]
  if type(fn) ~= "function" then return nil end
  return fn(obj, ...)
end

local function updateWidgetValue(w, key, val)
  if not w then return end
  if ui_cache[key] == val then return end
  ui_cache[key] = val
  safeCall(w, "value", val)
end

local function resetState(msg)
  requested = false
  loadedParams = false
  paramsRequested = false
  hasUnsavedChanges = false

  dev, info, params = nil, nil, nil
  errMsg = nil
  statusMsg = msg or "Starting…"
  lastStatusText = ""
  bindActive = false
  bindEndAt = 0

  ui.built = false
  ui.builtLoading = false
  ui.param = {}
  ui.status, ui.tx, ui.rx = nil, nil, nil
  ui.bindStatus, ui.bindButton = nil, nil
  ui.saveHint, ui.saveButton = nil, nil

  for k, _ in pairs(ui_cache) do ui_cache[k] = nil end

  dirtyForm = true
  dirtyHeader = true
  dirtyBind = true
  dirtySave = true
  lastRxAvailable = nil
  lastInfoPollAt = 0
end

local function statusText()
  if errMsg and errMsg ~= "" then
    return "ERR: " .. errMsg
  end
  return statusMsg or ""
end

local function updateStatusWidgets()
  updateWidgetValue(ui.status, "status", statusText())
end

local function updateHeaderWidgets()
  local tx = dev and dev.tx
  local rx = dev and dev.rx

  if tx and tx.name then
    updateWidgetValue(ui.tx, "tx", fmt(tx.name) .. " " .. fmt(tx.version_str))
  else
    updateWidgetValue(ui.tx, "tx", "")
  end

  if rx and rx.name then
    updateWidgetValue(ui.rx, "rx", fmt(rx.name) .. " " .. fmt(rx.version_str))
  else
    updateWidgetValue(ui.rx, "rx", "")
  end
end

local function setStatus(s)
  statusMsg = s or ""
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
    bindEndAt = now() + mlrs.DEFAULTS.BIND_TIMEOUT_S
    setStatus("Bind mode (" .. string.format("%.0f", mlrs.DEFAULTS.BIND_TIMEOUT_S) .. "s)…")
    dirtyBind = true
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
    dirtyBind = true
  end)
end

local function updateBindWidgets(tNow)
  if not ui.bindStatus then return end

  if bindActive then
    local left = math.max(0, bindEndAt - (tNow or now()))
    updateWidgetValue(ui.bindStatus, "bindStatus", "ACTIVE (auto-stop in " .. string.format("%.0f", left) .. "s)")
  else
    updateWidgetValue(ui.bindStatus, "bindStatus", "Idle")
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
    dirtyHeader = true

    setStatus("Requesting INFO…")
    api:getInfo(function(res2)
      if not res2.ok then
        setErr("Info: " .. fmt(res2.err))
        setStatus("Error")
        return
      end
      info = res2.data and res2.data.info or info
      setStatus("Ready")
      dirtyHeader = true
    end)
  end)
end

local function requestAllParams()
  if not api then return end
  setErr(nil)

  -- skip RX params if no receiver connected
  local skipRx = (info and info.rx_available ~= 1)
  
  if skipRx then
    setStatus("Loading Tx params…")
  else
    setStatus("Loading params…")
  end

  api:getAllParams(function(res)
    if not res.ok then
      setErr("Params: " .. fmt(res.err))
      setStatus("Error")
      return
    end
    params = res.data and res.data.params or nil
    loadedParams = true
    hasUnsavedChanges = false
    
    if skipRx then
      setStatus("Tx params loaded")
    else
      setStatus("Params loaded")
    end
    dirtySave = true

    -- Structural transition: loading screen -> params screen
    dirtyForm = true
  end, { full = true, deadlineS = mlrs.DEFAULTS.PARAM_LOAD_DEADLINE_S, skipRx = skipRx })
end

local function requestRxParams()
  -- called when RX connects after initial TX-only load
  if not api or not params then return end
  setStatus("Loading Rx params…")
  setErr(nil)

  -- first, refresh the RX device item to get name/version
  api:refreshRxItem(function(res)
    if res.ok and res.data and res.data.rx then
      dev = dev or {}
      dev.rx = res.data.rx
      dirtyHeader = true
    end
  end)

  -- clear cached RX params (from the defaults TX returned when RX was offline)
  -- keep TX params intact
  local model = api.model
  if model and model.params then
    for i, p in pairs(model.params) do
      if p and p.name and p.name:sub(1, 3) == "Rx " then
        model.params[i] = nil
      end
    end
    model.paramsComplete = false
  end
  
  -- also clear from our local params table
  for i, p in pairs(params) do
    if p and p.name and p.name:sub(1, 3) == "Rx " then
      params[i] = nil
    end
  end
  
  -- request all params - will skip TX (already loaded) and fetch fresh RX
  api:getAllParams(function(res)
    if not res.ok then
      setErr("RxParams: " .. fmt(res.err))
      setStatus("Error")
      return
    end
    -- merge new params into existing (fresh RX params will be added)
    local newParams = res.data and res.data.params or {}
    for i, p in pairs(newParams) do
      params[i] = p
    end
    setStatus("Rx params loaded")
    dirtyForm = true  -- rebuild UI to show RX params
  end, { full = true, deadlineS = mlrs.DEFAULTS.PARAM_LOAD_DEADLINE_S, skipRx = false })
end

local function pollInfo(tNow)
  -- periodically refresh INFO to detect RX connection changes
  if not api or not loadedParams then return end
  tNow = tNow or now()
  if (tNow - lastInfoPollAt) < 1.0 then return end  -- poll every 1s
  lastInfoPollAt = tNow

  api:refreshInfo(function(res)
    if not res.ok then return end
    local newInfo = res.data and res.data.info or nil
    if newInfo then
      info = newInfo
      dirtyHeader = true
    end
  end)
end

------------------------------------------------------------
-- Param field updates (in-place)
------------------------------------------------------------
local function updateSaveWidgets()
  if not ui.saveHint then return end
  if hasUnsavedChanges then
    updateWidgetValue(ui.saveHint, "saveHint", "Pending changes")
  else
    updateWidgetValue(ui.saveHint, "saveHint", "No pending changes")
  end
end

local function updateParamWidget(p)
  if not p then return end
  local f = ui.param[p.idx0]
  if not f then return end

  -- value
  safeCall(f, "value", p.value)

  -- type-specific metadata
  if p.paramType == mlrs.TYPES.LIST then
    -- LIST choices
    local choices = buildChoicesFromOptions(p.options)
    safeCall(f, "values", choices)
    -- Some firmwares expose min/max too; harmless if absent
    safeCall(f, "minimum", 0)
    safeCall(f, "maximum", math.max(#choices - 1, 0))
  elseif p.paramType ~= mlrs.TYPES.STR6 then
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
    dirtySave = true

    -- update UI in-place (no rebuild)
    updateParamWidget(p)

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
    dirtySave = true
    setStatus("Saved")
  end)
end

local function doReload()
  if not api then return end
  api:reset()
  resetState("Reloading…")
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
  for k, _ in pairs(ui_cache) do ui_cache[k] = nil end

  local line = form.addLine("Status")
  ui.status = form.addStaticText(line, nil, statusText())

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
  for k, _ in pairs(ui_cache) do ui_cache[k] = nil end

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

  -- Script version
  do
    local line = form.addLine("Script")
    form.addStaticText(line, nil, "mLRS Lua v" .. mlrs.VERSION)
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
  local rxAvailable = (info and info.rx_available == 1)
  if params then
    for i, p in pairs(params) do
      if p and p.name and p.name ~= "" then
        -- hide RX params when receiver not connected
        local isRxParam = (p.name:sub(1, 3) == "Rx ")
        if isRxParam and not rxAvailable then
          -- skip this param in UI
        else
          local label = p.name
          if p.unit and p.unit ~= "" then
            label = label .. " (" .. p.unit .. ")"
          end

          if p.editable then
            local line = form.addLine(label)

          if p.paramType == mlrs.TYPES.LIST then
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

          elseif p.paramType == mlrs.TYPES.STR6 then
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
    for _, p in pairs(params) do
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
    api = mlrs.new({ strategy = "by_index" })
    setmetatable(api, { __index = mlrs })
  end

  resetState()

  requestBasics()
  ensureForm()
  return {}
end

local function wakeup(_)
  if not api then return end
  api:processQueue()

  local tNow = now()

  -- Build structure if needed
  ensureForm()

  -- auto-stop bind after timeout
  if bindActive and bindEndAt and tNow >= bindEndAt then
    doBindStop()
  end

  -- Start param load exactly once after basics are ready
  if requested and not paramsRequested and not loadedParams and not errMsg and statusMsg == "Ready" then
    paramsRequested = true
    lastRxAvailable = (info and info.rx_available == 1)
    requestAllParams()
    bindActive = false
    bindEndAt = 0
  end

  -- Detect late RX connection and load RX params
  if loadedParams and info then
    pollInfo(tNow)  -- refresh info periodically to detect RX changes
    local nowRxAvailable = (info.rx_available == 1)
    if nowRxAvailable and lastRxAvailable == false then
      -- RX just connected - load RX params
      lastRxAvailable = true
      requestRxParams()
    elseif not nowRxAvailable and lastRxAvailable == true then
      -- RX disconnected - rebuild UI to hide RX params
      lastRxAvailable = false
      dirtyForm = true
    end
  end

  -- In-place “dynamic” UI updates (no rebuild)
  updateStatusWidgets()

  if dirtyHeader then
    updateHeaderWidgets()
    dirtyHeader = false
  end
  if dirtyBind then
    updateBindWidgets(tNow)
    dirtyBind = false
  end
  if dirtySave then
    updateSaveWidgets()
    dirtySave = false
  end
end


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
  local v = system.getVersion()
  if v.major > 1 or (v.major == 1 and v.minor >= 7) then
    system.registerMlrsModule({
      configure = { name = "MLRS", create = create, wakeup = wakeup, close = close }
    })
  else
    system.registerSystemTool({
      name = "MLRS", icon = icon, create = create, wakeup = wakeup, close = close
    })
  end
end

return { init = init }
