--[[
  Copyright (C) 2025 Rob Thomson
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
]] --


local mlrs = assert(loadfile("mlrs.lua"))()

------------------------------
-- Globals / UI state (singleton)
------------------------------
local icon = lcd and lcd.loadMask and lcd.loadMask("icon.png") or nil

local api = nil
local booted = false
local requested = false

local statusMsg = "Starting…"
local lastStatusAt = 0

local dev = nil     -- {tx=..., rx=..., info=...}
local info = nil    -- decoded info
local params = nil  -- param array
local errMsg = nil

local function setStatus(msg)
  statusMsg = msg or ""
  lastStatusAt = os.clock()
end

local function fmt(x)
  if x == nil then return "---" end
  return tostring(x)
end

local function create()
  if not api then
    api = mlrs.new({
      settleS = 1.5,
      strategy = "by_index",
      saveDeadS = 3.0,
    })
    booted = false
    requested = false
    dev, info, params, errMsg = nil, nil, nil, nil
    setStatus("Starting…")
  end
  return {}
end

local function kickRequests()
  if requested or not api then return end
  requested = true

  setStatus("Requesting device info…")

  api:getDeviceItems(function(res)
    if not res.ok then
      errMsg = "DeviceItems: " .. fmt(res.err)
      setStatus("Error: device items")
      return
    end

    dev = res.data
    if dev and dev.info then info = dev.info end
    setStatus("Device items ok. Requesting INFO…")

    api:getInfo(function(res2)
      if not res2.ok then
        errMsg = "Info: " .. fmt(res2.err)
        setStatus("Error: info")
        return
      end

      info = res2.data and res2.data.info or info
      setStatus("INFO ok. Loading parameters…")

      api:getAllParams(function(res3)
        if not res3.ok then
          errMsg = "Params: " .. fmt(res3.err)
          setStatus("Error: params")
          return
        end

        params = res3.data and res3.data.params or nil
        setStatus("Parameters loaded")
      end, { full = true, deadlineS = 30.0 })
    end)
  end)
end

local function wakeup(_)
  if not api then return end
  api:processQueue(24)

  if not booted then
    booted = true
    kickRequests()
  end
  lcd.invalidate()
end

local function event(_) end

local function paint(_)
  if not lcd then return end

  local y = 10
  lcd.drawText(10, y, "mLRS (API harness)", 0); y = y + 25

  if errMsg then
    lcd.drawText(10, y, "ERR: " .. fmt(errMsg), 0); y = y + 25
  end

  local txName = dev and dev.tx and dev.tx.name
  local rxName = dev and dev.rx and dev.rx.name
  lcd.drawText(10, y, "TX: " .. fmt(txName), LEFT); y = y + 20
  lcd.drawText(10, y, "RX: " .. fmt(rxName), LEFT); y = y + 20

  if info then
    lcd.drawText(10, y, "TxPwr: " .. fmt(info.tx_power_dbm) .. " dBm", LEFT); y = y + 20
    lcd.drawText(10, y, "RxPwr: " .. fmt(info.rx_power_dbm) .. " dBm", LEFT); y = y + 20
    lcd.drawText(10, y, "Sens: " .. fmt(info.receiver_sensitivity) .. " dBm", LEFT); y = y + 20
    lcd.drawText(10, y, "Div: T" .. fmt(info.tx_diversity) .. " R" .. fmt(info.rx_diversity), LEFT); y = y + 20
  else
    lcd.drawText(10, y, "INFO: ---", 0); y = y + 20
  end

  local pcount = 0
  if params then
    for i = 1, #params do
      local p = params[i]
      if p and p.name then pcount = pcount + 1 end
    end
  end
  lcd.drawText(10, y, "Params: " .. tostring(pcount), 0); y = y + 20

  lcd.drawText(10, y + 10, "Status: " .. fmt(statusMsg), 0)
end

local function close(_) end

local function init()
  local version = system.getVersion()
  local major, minor = version.major, version.minor

  if major >= 1 and minor >= 7 then
    system.registerMlrsModule({
      configure = { name = "MLRS", create = create, wakeup = wakeup, event = event, close = close, paint = paint }
    })
  else
    system.registerSystemTool({
      name = "MLRS", icon = icon, create = create, wakeup = wakeup, event = event, paint = paint, close = close
    })
  end
end

return { init = init }
