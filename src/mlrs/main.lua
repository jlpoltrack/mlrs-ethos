--[[
  Copyright (C) 2025 Rob Thomson
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
]] --

------------------------------
-- Globals / UI state
------------------------------
local fields = {}
local icon = lcd and lcd.loadMask and lcd.loadMask("icon.png") or nil

-- flags
local fieldWidgetsBuilt = false         -- whether UI widgets have been created
local mb_have_info, mb_got_info, mb_params_complete = false, false, false
local mb_requested_info, mb_requested_params = false, false
local triggerSave = false
local formFields = {}
local lastFocusedIndex = nil  -- track the last edited/focused field

-- debug counters
local rx_any_count, rx_vendor130_count = 0, 0
local last_vendor_hex = ""

------------------------------
-- mBridge constants
------------------------------
local A0 = 0xA0
local CMD_REQUEST_INFO        = 3
local CMD_DEVICE_ITEM_TX      = 4
local CMD_DEVICE_ITEM_RX      = 5
local CMD_PARAM_REQUEST_LIST  = 6
local CMD_PARAM_ITEM          = 7
local CMD_PARAM_ITEM2         = 8
local CMD_PARAM_ITEM3         = 9
local CMD_INFO                = 11
local CMD_PARAM_SET           = 12
local CMD_PARAM_STORE         = 13

-- types
local T_UINT8, T_INT8, T_UINT16, T_INT16, T_LIST, T_STR6 = 0,1,2,3,4,5

------------------------------
-- Drain frames
------------------------------
local function drainFrames(sensor, max)
  max = max or 64
  for _ = 1, max do
    local cmd, _ = sensor:popFrame(130)
    if not cmd then break end
  end
end

------------------------------
-- Check telemetry active
------------------------------
local function isTelemetryActive()
  local tlm = system.getSource({
    category = CATEGORY_SYSTEM_EVENT,
    member   = TELEMETRY_ACTIVE
  })
  return tlm and (tlm:value() == 1)
end

------------------------------
-- Reset state
------------------------------
local function resetState()
  fields = {}
  fieldWidgetsBuilt = false
  lastFocusedIndex = nil

  -- protocol flags
  mb_have_info, mb_got_info, mb_params_complete = false, false, false
  mb_requested_info, mb_requested_params = false, false
end

------------------------------
-- Sensor / create
------------------------------
local function create()
  resetState()
  local sensor
  if crsf and crsf.getSensor then
    sensor = crsf.getSensor()
  else
    sensor = { popFrame=function(self) return crsf.popFrame() end,
               pushFrame=function(self,id,data) return crsf.pushFrame(id,data) end }
  end
  drainFrames(sensor)
  return { sensor = sensor }
end

------------------------------
-- Utils
------------------------------
local function hexdump(arr, limit)
  if not arr then return "" end
  local n = #arr; local k = math.min(n, limit or 32)
  local t = {}
  for i=1,k do t[#t+1] = string.format("%02X", arr[i]) end
  if n>k then t[#t+1] = "…" end
  return table.concat(t, " ")
end

local function u8(p,i) return p[i+1] & 0xFF end
local function i8(p,i) local v=u8(p,i); if v>127 then v=v-256 end; return v end
local function u16(p,i) return u8(p,i) + (u8(p,i+1) << 8) end
local function i16(p,i)
  local v = u16(p,i)
  if v > 32767 then v = v - 65536 end
  return v
end

local function mb_value_by_type(p,i,typ)
  if     typ==T_UINT8  then return u8(p,i),1
  elseif typ==T_INT8   then return i8(p,i),1
  elseif typ==T_UINT16 then return u16(p,i),2
  elseif typ==T_INT16  then return i16(p,i),2
  elseif typ==T_STR6   then
    local s={}; for k=0,5 do local b=p[i+1+k]; if not b or b==0 then break end; s[#s+1]=string.char(b) end
    return table.concat(s),6
  end
  return 0,0
end

local function mb_str(p, i, n)
  local s={}; for k=0,n-1 do local b=p[i+1+k]; if not b or b==0 then break end; s[#s+1]=string.char(b) end
  return table.concat(s)
end

local function cmd_len(cmd)
  if cmd==CMD_PARAM_ITEM or cmd==CMD_PARAM_ITEM2 or cmd==CMD_PARAM_ITEM3 then return 24 end
  if cmd==CMD_DEVICE_ITEM_TX or cmd==CMD_DEVICE_ITEM_RX then return 24 end
  if cmd==CMD_INFO then return 24 end
  if cmd==CMD_PARAM_SET then return 7 end
  return 0
end

local function pushMB(sensor, cmd, payload)
  local data = { string.byte('O'), string.byte('W'), A0 + cmd }
  local need = cmd_len(cmd)
  for i=1,need do data[#data+1]=0 end
  for i=1,#payload do data[3+i]=payload[i] end
  return sensor:pushFrame(129, data)
end

-- Parse LIST options exactly like the EdgeTX reference:
-- bytes are a comma-separated string; stop at first NUL; clear high-bit.
local function parse_list_options_csv_from_payload(payload, startOfs, endOfs)
  local bytes = {}
  for ofs = startOfs, endOfs do
    local b = u8(payload, ofs)
    if not b or b == 0 then break end
    bytes[#bytes+1] = b
  end

  local s = {}
  for _, b in ipairs(bytes) do
    s[#s+1] = string.char(b & 0x7F)
  end
  local str = table.concat(s)

  local opts = {}
  for part in string.gmatch(str .. ",", "([^,]+)") do
    -- trim
    part = part:match("^%s*(.-)%s*$")
    if part ~= "" then opts[#opts+1] = part end
  end
  return opts
end

-- Build f.options from ITEM2/ITEM3 with high-bit cleared
local function parse_list_bytes_to_options(bytes)
  local opts, buf = {}, {}
  for _, b in ipairs(bytes) do
    if b == 0 then
      if #buf > 0 then
        opts[#opts+1] = table.concat(buf)
        buf = {}
      end
    else
      -- clear high bit so labels don't start with '�'
      local ch = string.char(bit32 and bit32.band(b, 0x7F) or (b & 0x7F))
      buf[#buf+1] = ch
    end
  end
  if #buf > 0 then opts[#opts+1] = table.concat(buf) end
  return opts
end

------------------------------
-- Progress loader (single, persistent)
------------------------------
local prog = {
  open = false,
  speedFast = false,
  startedAt = nil,
  counter = 0,
  mode = nil,            -- "load" | "save" | "reload"
  timeout = 24.0,         -- default seconds (overridden per mode)
  dlg = nil,
  -- save/reset handling
  lastRxAt = nil,        -- last time we saw any frame
  lastParamRxAt = nil,   -- last time we saw any PARAM_ITEM/2/3 frame
  saveMin = 1.0,         -- don't auto-complete save before this many seconds
  saveQuiet = 1.2,       -- if we've had no frames for this long after saveMin, assume power cycle and advance
  -- post-save reload handling
  reloading = false,     -- true while we wait for device to come back after save
  reloadStart = nil,
  postSaveReloadTimeout = 25.0 -- how long to wait for packets to return after save
}

local function hardReset(widget)

  -- stop/clear progress UI state
  prog.open = false
  prog.speedFast = false
  prog.startedAt = nil
  prog.counter = 0
  prog.mode = nil
  prog.dlg = nil

  -- clear retry / reconnect timing
  prog.lastRxAt = nil
  prog.lastInfoReq = nil
  prog.lastParamsReq = nil
  prog.reloading = false
  prog.reloadStart = nil

  -- reset protocol/UI state
  resetState()

  -- restart the “settle” window on next wakeup
  if widget and type(widget) == "table" then
    widget._enteredAt = os.clock()
  end
end

local function progressOpen(title, message, speedFast, mode)
  if prog.open then return end
  prog.open = true
  prog.speedFast = speedFast and true or false
  prog.startedAt = os.clock()
  prog.counter = 0
  prog.mode = mode or "load"
  -- adjust timeout per mode
  prog.timeout = (prog.mode == "save") and 24.0 or 12.0
  prog.lastRxAt = os.clock()

  prog.dlg = form.openProgressDialog({
    title = title or (mode=="save" and "Saving…" or "Loading…"),
    message = message or (mode=="save" and "Writing to device" or "Reading from device"),
    close = function() 
       hardReset(prog.widget)
       system.exit()
    end,
    wakeup = function()
      local mult = prog.speedFast and 1.5 or 1
      -- drift forward unless we already finished
      prog.counter = prog.counter + (1 * mult)
      local cap = (prog.mode=="save") and 90 or 95
      if prog.counter > cap then prog.counter = cap end
      if prog.dlg and prog.dlg.value then prog.dlg:value(prog.counter) end

      -- watchdog
      if prog.lastRxAt and (os.clock() - prog.lastRxAt) > prog.timeout then
        if prog.dlg then
          prog.dlg:message("Timed out")
          prog.dlg:closeAllowed(true)
          prog.dlg:value(100)
        end
      end
    end
  })
  if prog.dlg then
    prog.dlg:value(0)
    prog.dlg:closeAllowed(false)
  end
end

-- NEW: update the existing progress dialog in-place (mode/message/speed/timeout)
local function progressEnsure(opts)
  -- opts = {mode=, title=, message=, speedFast=, timeout=}
  if not prog.open then
    progressOpen(opts and opts.title, opts and opts.message, opts and opts.speedFast, opts and opts.mode)
    if opts and opts.timeout then prog.timeout = opts.timeout end
    return
  end
  if opts then
    if opts.mode and prog.mode ~= opts.mode then
      prog.mode = opts.mode
      prog.startedAt = os.clock()
      prog.counter = 0
    end
    if opts.speedFast ~= nil then prog.speedFast = opts.speedFast and true or false end
    if opts.timeout then prog.timeout = opts.timeout end
    if opts.message and prog.dlg and prog.dlg.message then prog.dlg:message(opts.message) end
    -- NOTE: ETHOS API doesn't expose a title setter; we update message only.
  end
  if prog.dlg and prog.dlg.closeAllowed then prog.dlg:closeAllowed(false) end
end

local function progressClose()
  if not prog.open then return end
  if prog.dlg then
    pcall(function()
      prog.dlg:value(100)
      prog.dlg:close()
    end)
  end
  prog.open, prog.speedFast, prog.startedAt, prog.counter, prog.mode, prog.dlg = false, false, nil, 0, nil, nil
  -- restore focus to the last edited field when possible
  if lastFocusedIndex and formFields[lastFocusedIndex] and formFields[lastFocusedIndex].focus then
    formFields[lastFocusedIndex]:focus()
  else
    -- sensible fallback to the first interactive field, if available
    if formFields[2] and formFields[2].focus then
      formFields[2]:focus()
    end
  end
end

------------------------------
-- Save confirmation dialog
------------------------------
local _saveDialogOpen = false
local function openSaveDialog(widget)
  if _saveDialogOpen then return end
  _saveDialogOpen = true

  form.openDialog({
    title   = "Save settings?",
    message = "Store parameters to device flash now?",
    buttons = {
      {
        label  = "OK",
        action = function()
          -- kick off SAVE
          pushMB(widget.sensor, CMD_PARAM_STORE, {})
          -- mark UI state so loader logic knows we are in a SAVE cycle
          mb_params_complete  = false
          mb_requested_params = false
          fieldWidgetsBuilt   = false
          -- show progress for save (will persist through reboot + reload)
          progressEnsure({ mode = "save", message = "Writing to device…", speedFast = true, timeout = 12.0 })
          prog.lastRxAt = os.clock(); prog.reloading=false; prog.reloadStart=nil
          _saveDialogOpen = false
          return true -- close confirmation dialog
        end
      },
      {
        label  = "Cancel",
        action = function()
          _saveDialogOpen = false
          return true
        end
      }
    },
    wakeup  = function() end,
    paint   = function() end,
    options = TEXT_LEFT
  })
end

------------------------------
-- UI builder (build-once)
------------------------------
local function buildForm(widget)
  form.clear()

  -- fields
  for idx=1,#fields do
    local f = fields[idx]
    if f and f.name then
      if f.typ==T_UINT8 or f.typ==T_INT8 or f.typ==T_UINT16 or f.typ==T_INT16 then
        local ln = form.addLine(f.name)
        local min = f.min or 0; local max = f.max or 65535
        local getter = function() return f.value or 0 end
        local setter = function(val)
          lastFocusedIndex = idx  -- remember which control was just edited
          f.value = val
          local bytes = (f.typ==T_UINT16 or f.typ==T_INT16) and 2 or 1
          local payload = { (idx-1) & 0xFF }
          local v=val; for i=1,bytes do payload[#payload+1]= v & 0xFF; v = v>>8 end
          pushMB(widget.sensor, CMD_PARAM_SET, payload)
        end
        formFields[idx] = form.addNumberField(ln, nil, min, max, getter, setter)
        if f.unit and formFields[idx].suffix then formFields[idx]:suffix(f.unit) end
        formFields[idx]:enableInstantChange(true)

        elseif f.typ==T_LIST then

          -- choices MUST be { {"Label", value}, ... } on Ethos
          local choices = {}
          local opts = f.options or {}

          for i = 1, #opts do
            local label = tostring(opts[i] or "")
            -- skip invalid placeholders like "-"
            if label ~= "-" and label ~= "" then
              choices[#choices+1] = { label, i - 1 }  -- 0-based values
            end
          end

          -- fallback if no valid options remain
          if #choices == 0 then
            choices = { { "-", 0 } }
          end

          local getter = function()
            local v = tonumber(f.value) or 0
            if v < 0 then v = 0 end
            if v > #choices - 1 then v = #choices - 1 end
            return v
          end

          local setter = function(val)
            lastFocusedIndex = idx
            f.value = tonumber(val) or 0
            pushMB(widget.sensor, CMD_PARAM_SET, { (idx-1) & 0xFF, (f.value or 0) & 0xFF })
          end

          if #choices == 1 then
            print("Warning: field index "..tostring(idx).." has no valid options; skip render")
          else
            local ln = form.addLine(f.name)
            formFields[idx] = form.addChoiceField(ln, nil, choices, getter, setter)
          end

      elseif f.typ==T_STR6 then
        local ln = form.addLine(f.name)
        formFields[idx] = form.addStaticText(ln, nil, tostring(f.value or ""))
      end
    end
  end

  -- footer action
  local saveLine = form.addLine("Store settings")
  formFields['save'] = form.addTextButton(saveLine, nil, "Save", function()
    triggerSave = true
  end)
end

------------------------------
-- Parsers (no rebuilding inside)
------------------------------
local function on_ITEM(widget, payload)
  local idx = payload[1] or 255
  if idx==255 then
    mb_params_complete = true
    if not fieldWidgetsBuilt then
      buildForm(widget)
      fieldWidgetsBuilt = true
    end
    return
  end

  local k = idx+1
  fields[k] = fields[k] or { id=k }
  local f = fields[k]

  f.typ  = u8(payload,1)
  f.name = mb_str(payload,2,16)
  if f.typ==T_LIST and f.options==nil then f.options = {} end

  if f.typ == T_LIST then
    -- ITEM carries the option CSV in bytes 2..23 AND the current value in byte 18.
    -- Note: 18 is within 2..23, but the reference still uses this layout.
    f.options = parse_list_options_csv_from_payload(payload, 2, 23)
    f.min, f.max = 0, math.max(#(f.options or {}) - 1, 0)
    f.value = (u8(payload,18) or 0) & 0x7F
    if f.value > f.max then f.value = f.max end
    return
  end

  f.value = select(1, mb_value_by_type(payload,18,f.typ))
end

local function on_ITEM2(widget, payload)
  local idx = payload[1]; if not idx then return end
  local k = idx+1; local f = fields[k]; if not f then return end

  if f.typ==T_LIST then
   -- EdgeTX-style: ITEM2 continues the comma-separated option string
    -- (some firmwares may send options split across ITEM/ITEM2/ITEM3).
    -- For now we treat ITEM2 as a full replacement if it contains data.
    local opts = parse_list_options_csv_from_payload(payload, 2, 23)
    if opts and #opts > 0 then
      f.options = opts
    else
      f.options = f.options or {}
    end
    f.min, f.max = 0, math.max(#(f.options or {}) - 1, 0)
    if type(f.value)=="number" and f.value > f.max then f.value = f.max end
  else
    f.min = select(1, mb_value_by_type(payload, 1, f.typ))
    f.max = select(1, mb_value_by_type(payload, 3, f.typ))
    f.unit = mb_str(payload, 7, 6)
  end
end

local function on_ITEM3(widget, payload)
  -- Optional: extend options or units
end

------------------------------
-- Wakeup loop (single loader orchestration)
------------------------------
local function wakeup(widget)
  prog.widget = widget
  local now = os.clock()

  -- Reacquire CRSF sensor handle if it went stale after power-cycle
  if (not widget.sensor or not widget.sensor.pushFrame) and crsf and crsf.getSensor then
    widget.sensor = crsf.getSensor()
  end


  widget._enteredAt = widget._enteredAt or os.clock()

  -- Allow module / CRSF stack to settle
  if os.clock() - widget._enteredAt < 1.5 then
    progressEnsure({
      mode = "load",
      message = "Waiting for device…",
      speedFast = false,
      timeout = 10.0
    })
    return
  end  

  -- During reconnect, give the device a moment to boot before sending requests
  if prog.reloading and (os.clock() - (prog.reloadStart or 0)) < 3.0 then
    -- keep loader visible with reconnect message
    progressEnsure({ mode = "reload", message = "Reconnecting to device…", speedFast = false, timeout = prog.postSaveReloadTimeout })
    return
  end

  if triggerSave then
    triggerSave = false
    openSaveDialog(widget)
  end

  -- READ frames
  for _= 1,24 do --read 24 frames per wakeup
    local cmd, data = widget.sensor:popFrame(130)
    if not cmd then break end
    rx_any_count = rx_any_count + 1
    prog.lastRxAt = now
    -- Any packet means the link is back. If we were in post-save reload,
    -- fully restart the protocol state machine so INFO/PARAM requests resume cleanly.
    if prog.reloading then
      prog.reloading = false
      prog.reloadStart = nil
      prog.lastInfoReq = nil
      prog.lastParamsReq = nil
      prog.lastParamRxAt = nil
      mb_have_info, mb_got_info, mb_params_complete = false, false, false
      mb_requested_info, mb_requested_params = false, false
      fieldWidgetsBuilt = false
      -- restart settle window so we don't immediately spam while CRSF stack stabilises
      widget._enteredAt = os.clock()
    end

    if cmd==130 and data and data[1] then
      rx_vendor130_count = rx_vendor130_count + 1
      last_vendor_hex = hexdump(data, 32)
      local mcmd = data[1] - A0
      local payload = {}
      for i=2,#data do payload[#payload+1]=data[i] end

      if mcmd==CMD_INFO then
        mb_have_info = true
        mb_got_info = true
      elseif mcmd==CMD_DEVICE_ITEM_TX then
        mb_have_info = true
      elseif mcmd==CMD_DEVICE_ITEM_RX then
        if isTelemetryActive() then
          mb_have_info = true
        end  
      elseif mcmd==CMD_PARAM_ITEM then
        prog.lastParamRxAt = now
        on_ITEM(widget, payload)
      elseif mcmd==CMD_PARAM_ITEM2 then
        prog.lastParamRxAt = now
        on_ITEM2(widget, payload)
      elseif mcmd==CMD_PARAM_ITEM3 then
        prog.lastParamRxAt = now
        on_ITEM3(widget, payload)
      end
    end
  end

  -- SEND probes
  -- IMPORTANT: while STORE is in progress, don't spam INFO/PARAM requests.
  -- It can interfere with flash write / reboot and make "save" appear to never work.
  local savingNow = (prog.mode == "save") and (not prog.reloading)

  if not savingNow then  
    -- Only begin PARAM sync once we have seen CMD_INFO; some modules will ignore
    -- CMD_PARAM_REQUEST_LIST until they are fully initialised.
    if not mb_got_info then
      if (not prog.lastInfoReq) or (now - prog.lastInfoReq > 1.0) then
        if widget.sensor and widget.sensor.pushFrame then
          pushMB(widget.sensor, CMD_REQUEST_INFO, {})
          prog.lastInfoReq = now
          mb_requested_info = true
        end
      end
    elseif not mb_params_complete then
      -- Don't spam CMD_PARAM_REQUEST_LIST: it can restart/fragment the stream.
      -- Only re-request if we appear idle (no param frames coming in).
      local idleFor = now - (prog.lastParamRxAt or 0)
      local canRequest = (not prog.lastParamsReq) or (now - prog.lastParamsReq > 2.0)
      local streamIdle = (prog.lastParamRxAt == nil) or (idleFor > 1.2)

      if canRequest and streamIdle then
        if widget.sensor and widget.sensor.pushFrame then
          pushMB(widget.sensor, CMD_PARAM_REQUEST_LIST, {})
          prog.lastParamsReq = now
          mb_requested_params = true
        end
      end
    end
  end  

  -- PROGRESS orchestration (single dialog)
  -- Ensure loader is open/updated whenever we are missing info/params
  if (not mb_have_info or not mb_params_complete) then
    local isReload = prog.reloading and (os.clock() - (prog.reloadStart or 0) < prog.postSaveReloadTimeout)
    local msg = isReload and "Reconnecting to device…" or ((prog.mode=="save") and "Writing to device…" or "Reading from device…")
    local mode = isReload and "reload" or (prog.mode or "load")
    progressEnsure({ mode = mode, message = msg, speedFast = (mode=="save"), timeout = isReload and prog.postSaveReloadTimeout or ((mode=="save") and 12.0 or 6.0) })
  end

  -- Close loader once UI is built and params complete (and we're not in a forced timeout)
  if prog.open and mb_have_info and mb_params_complete and fieldWidgetsBuilt and not prog.reloading then
    progressClose()
  end

  -- SAVE cycle management: do not close; convert to RELOAD state and keep dialog open
  if prog.mode=="save" then
    if mb_params_complete and fieldWidgetsBuilt then
      -- normal completion immediately advances to reload
      -- (lastFocusedIndex is preserved across the save→reload cycle so focus returns post-reload)
      prog.reloading = true
      prog.reloadStart = now
      mb_have_info, mb_params_complete = false, false
      mb_requested_info, mb_requested_params = false, false
      fieldWidgetsBuilt = false
      progressEnsure({ mode = "reload", message = "Reconnecting to device…", speedFast = false, timeout = prog.postSaveReloadTimeout })
    else
      -- Device often power-cycles on STORE; if we go quiet for a bit, treat as success → reload
      local sinceStart = now - (prog.startedAt or now)
      -- Only treat PARAM frames as "activity" so other link traffic doesn't prevent completion.
      local sinceParam = now - (prog.lastParamRxAt or prog.startedAt or now)
      if sinceStart > prog.saveMin and sinceParam > prog.saveQuiet then
        prog.reloading = true
        prog.reloadStart = now
        mb_have_info, mb_params_complete = false, false
        mb_requested_info, mb_requested_params = false, false
        fieldWidgetsBuilt = false
        progressEnsure({ mode = "reload", message = "Reconnecting to device…", speedFast = false, timeout = prog.postSaveReloadTimeout })
      end
    end
  end
end

local function event(widget, category, value, x, y)
  if value == KEY_ENTER_LONG then
       triggerSave = true
       system.killEvents(KEY_ENTER_BREAK)
    return true
  end
  return false
end

local function paint(widget)

end

local function close(widget)
  progressClose()
  resetState()
  hardReset(widget)
  if collectgarbage then collectgarbage() end
  widget.sensor = nil
end

local function init()
  local version = system.getVersion()
  local major, minor = version.major, version.minor
  if major >= 1 and minor >= 7 then
    -- in ethos 1.7 and higher we register as a module
    system.registerMlrsModule({configure = {name = "MLRS", create = create, wakeup = wakeup, event = event, close = close}})
  else
    system.registerSystemTool({ name = "MLRS", icon = icon, create = create, wakeup = wakeup, event = event, paint = paint, close = close })
  end

end

return { init = init }
