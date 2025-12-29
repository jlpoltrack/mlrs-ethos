--[[
  Copyright (C) 2025 Rob Thomson
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
]] --

local BASE = "RADIO:/scripts/mlrs"

local mlrs = assert(loadfile(BASE .. "/mlrs.lua"))()

------------------------------------------------------------
-- Singleton state (forms app is typically single-instance)
------------------------------------------------------------
local icon = lcd and lcd.loadMask and lcd.loadMask(BASE .. "/icon.png") or nil

local api
local requested = false
local loadedParams = false

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
  end, { full = true, deadlineS = 30.0 })
end

local function doSave()
  if not api then return end
  setStatus("Saving…")
  setErr(nil)

  api:store(function(res)
    if not res.ok then
      setErr("Store: " .. fmt(res.err))
      setStatus("Error")
      return
    end
    -- After store(), device may pause / reboot; we mark dirty and let user reload/refresh.
    setStatus("Saved (reloading recommended)")
  end)
end

local function doReload()
  if not api then return end
  api:reset()
  requested = false
  loadedParams = false
  dev, info, params = nil, nil, nil
  setErr(nil)
  setStatus("Reloading…")
  requestBasics()
end

------------------------------------------------------------
-- Form builder (Forms API)
------------------------------------------------------------
local function addButtonLine(label, buttonText, pressFn)
  local line = form.addLine(label)
  -- Ethos supports addButton (since 1.5.10) and addTextButton (deprecated). :contentReference[oaicite:1]{index=1}
  if form.addButton then
    form.addButton(line, nil, { text = buttonText, press = pressFn })
  else
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

  form.addStaticText(form.addLine("Status"), nil, errMsg and ("ERR: " .. errMsg) or statusMsg)

  form.addStaticText(form.addLine("TX Name"), nil, fmt(tx and tx.name))
  form.addStaticText(form.addLine("TX Ver"),  nil, fmt(tx and tx.version_str))

  form.addStaticText(form.addLine("RX Name"), nil, fmt(rx and rx.name))
  form.addStaticText(form.addLine("RX Ver"),  nil, fmt(rx and rx.version_str))

  form.addStaticText(form.addLine("Tx Power"), nil, info and (fmt(info.tx_power_dbm) .. " dBm") or "---")
  form.addStaticText(form.addLine("Rx Power"), nil, info and (fmt(info.rx_power_dbm) .. " dBm") or "---")
  form.addStaticText(form.addLine("Sensitivity"), nil, info and (fmt(info.receiver_sensitivity) .. " dBm") or "---")
  form.addStaticText(form.addLine("Diversity"), nil, info and ("T" .. fmt(info.tx_diversity) .. " / R" .. fmt(info.rx_diversity)) or "---")

  form.addStaticText(form.addLine("Params loaded"), nil, loadedParams and "Yes" or "No")

  addButtonLine("Actions", "Reload", function()
    doReload()
  end)

  addButtonLine(" ", "Load params", function()
    requestAllParams()
  end)

  addButtonLine(" ", "Save", function()
    doSave()
  end)

  -- You’ll replace the below with your real UI pages.
  if loadedParams and params then
    local count = 0
    for i = 1, #params do
      local p = params[i]
      if p and p.name then count = count + 1 end
      if count >= 5 then break end
    end
    form.addStaticText(form.addLine("Param preview"), nil, "First 5 loaded (UI to come)")
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
