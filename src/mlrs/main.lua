--[[
  Copyright (C) 2025 Rob Thomson
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
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
local errMsg

local dev -- {tx=..., rx=..., info=...}
local info
local params

-- form rebuild throttle
local dirty = true
local lastBuildAt = 0

local function now() return os.clock() end
local function fmt(x) return (x == nil) and "---" or tostring(x) end

local function setStatus(s)
  statusMsg = s or ""
  dirty = true
end

local function setErr(s)
  errMsg = s
  dirty = true
end

------------------------------------------------------------
-- UI helpers (matching the upstream script style)
------------------------------------------------------------
local function buildChoicesFromOptions(opts)
  local choices = {}
  opts = opts or {}
  for i = 1, #opts do
    local label = tostring(opts[i] or "")
    if label ~= "-" and label ~= "" then
      choices[#choices + 1] = { label, i - 1 } -- 0-based values
    end
  end
  if #choices == 0 then choices = { { "-", 0 } } end
  return choices
end

local function safeStatic(label, value)
  local line = form.addLine(label or "")
  form.addStaticText(line, nil, value or "")
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
    setStatus("Params loaded")
    dirty = true
  end, { full = true, deadlineS = 30.0 })
end

local function doSave()
  if not api then return end
  setErr(nil)
  setStatus("Saving…")
  api:store(function(res)
    if not res.ok then
      setErr("Store: " .. fmt(res.err))
      setStatus("Error")
      return
    end
    setStatus("Saved")
    dirty = true
  end)
end

local function doReload()
  if not api then return end
  api:reset()
  requested = false
  loadedParams = false
  paramsRequested = false
  dev, info, params = nil, nil, nil
  setErr(nil)
  setStatus("Reloading…")
  requestBasics()
end

------------------------------------------------------------
-- Form builder (Forms API)
------------------------------------------------------------
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
    p.value = newValue
    setStatus("Ready")
    dirty = true
  end)
end

------------------------------------------------------------
-- Button helper
------------------------------------------------------------
local function addButtonLine(label, buttonText, pressFn)
  local line = form.addLine(label or "")
  if form.addButton then
    form.addButton(line, nil, { text = buttonText, press = pressFn })
  else
    -- older Ethos
    form.addTextButton(line, nil, buttonText, pressFn)
  end
end

local function buildForm()
  -- debounce rebuild
  local t = now()
  if (t - lastBuildAt) < 0.25 then return end
  lastBuildAt = t
  dirty = false

  form.clear()

  local tx = dev and dev.tx
  local rx = dev and dev.rx

  -- One compact status line
  safeStatic("Status", errMsg and ("ERR: " .. errMsg) or statusMsg)

  addButtonLine("", "Save", function() doSave() end)

  -- A tiny bit of identity is handy, but keep it minimal
  if tx and tx.name then
    safeStatic("TX", fmt(tx.name) .. " " .. fmt(tx.version_str))
  end
  if rx and rx.name then
    safeStatic("RX", fmt(rx.name) .. " " .. fmt(rx.version_str))
  end

  -- Avoid building a giant partial form while params are still arriving
  if not loadedParams or not params then
    safeStatic("", "Loading parameters…")
    return
  end

  -- Render ALL params in index order (as received/decoded)
  for i = 1, #params do
    local p = params[i]
    if p and p.name and p.name ~= "" then
      local label = p.name
      if p.unit and p.unit ~= "" then
        label = label .. " (" .. p.unit .. ")"
      end
      local line = form.addLine(label)

      local editable = (p.editable ~= false)

      if not editable then
        if p.typ == 4 and p.options and #p.options > 0 then
          form.addStaticText(line, nil, p.options[(p.value or 0) + 1] or fmt(p.value))
        else
          form.addStaticText(line, nil, fmt(p.value))
        end
      else
        if p.typ == 4 then
          -- LIST: Ethos expects choices = { {"Label", value}, ... }
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
          if #choices == 1 then
            -- nothing meaningful to choose; render static to avoid warnings
            form.addStaticText(line, nil, tostring(p.options and p.options[1] or "-"))
          else
            local w = form.addChoiceField(line, nil, choices, getter, setter)
            if w and w.enableInstantChange then w:enableInstantChange(true) end
          end
        elseif p.typ == 5 then
          -- STR6: shown read-only (CMD_PARAM_SET is 1-byte in mlrs.lua currently)
          form.addStaticText(line, nil, fmt(p.value))
        else
          -- numeric types
          local min = p.min or 0
          local max = p.max or 65535
          local getter = function() return p.value or 0 end
          local setter = function(val) commitParam(p, val) end
          local w = form.addNumberField(line, nil, min, max, getter, setter)
          if w and p.unit and w.suffix then w:suffix(p.unit) end
          if w and w.enableInstantChange then w:enableInstantChange(true) end
        end
      end
    end
  end
end

------------------------------------------------------------
-- Tool / module lifecycle
------------------------------------------------------------
local function create()
  if not api then
    api = mlrs.new({ settleS = 1.5, strategy = "by_index", saveDeadS = 3.0 })
    -- Ensure instance methods work: api:processQueue(), api:getInfo(), etc.
    setmetatable(api, { __index = mlrs })
  end

  requested = false
  loadedParams = false
  dev, info, params = nil, nil, nil
  errMsg = nil
  statusMsg = "Starting…"
  dirty = true

  requestBasics()
  buildForm()
  return {}
end

local function wakeup(_)
  if not api then return end
  api:processQueue(24)

  -- Start param load exactly once after basics are ready
  if requested and not paramsRequested and not loadedParams and not errMsg and statusMsg == "Ready" then
    paramsRequested = true
    requestAllParams()
  end

  -- If data arrived / state changed, rebuild the form (debounced)
  if dirty then
    buildForm()
  end
end

local function event(_) end
local function paint(_) end
local function close(_) end

local function init()
  local v = system.getVersion()
  if v.major >= 1 and v.minor >= 7 then
    system.registerMlrsModule({
      configure = { name = "MLRS", create = create, wakeup = wakeup, event = event, close = close }
    })
  else
    system.registerSystemTool({
      name = "MLRS", icon = icon, create = create, wakeup = wakeup, event = event, paint = paint, close = close
    })
  end
end

return { init = init }
