-- mlrs.lua
-- Lightweight queued API for mLRS modules (Ethos / CRSF sensor frames)
--
-- This module implements a pull-based parameter loading system that communicates
-- with mLRS devices via the mBridge layer over CRSF telemetry. It handles 
-- asynchronous requests for device info, parameters (including multi-frame
-- enrichment ITEM2/3/4), and module actions like binding and saving.
--
-- Dependencies: Ethos 'crsf' and 'os' globals.
-- Date: 2026-01-02

local M = {}
M.VERSION = "1.0.0"
M.TYPES = { UINT8=0, INT8=1, UINT16=2, INT16=3, LIST=4, STR6=5 }

-- configurable defaults (timing in seconds)
local DEFAULTS = {
  SETTLE_S = 0.0,
  SAVE_DEAD_S = 3.0,
  -- retry intervals (time before re-sending if no response)
  REQ_INTERVAL_INDEX_S = 0.100,  -- retry param-by-index requests
  REQ_INTERVAL_INFO_S = 1.0,     -- retry info/device requests
  REQ_INTERVAL_LIST_S = 2.0,     -- param list streaming
  -- deadlines
  DEADLINE_SHORT_S = 6.0,        -- set, bind, boot
  DEADLINE_MEDIUM_S = 8.0,       -- info, device items
  DEADLINE_PARAM_S = 10.0,       -- single param
  DEADLINE_LONG_S = 25.0,        -- all params, store
  -- ui-specific
  PARAM_LOAD_DEADLINE_S = 30.0,  -- overall param load timeout
  BIND_TIMEOUT_S = 20.0,         -- bind mode auto-stop
}
M.DEFAULTS = DEFAULTS

-- mBridge constants
local A0 = 0xA0
local CMD_TX_LINK_STATS       = 2
local CMD_REQUEST_INFO        = 3
local CMD_DEVICE_ITEM_TX      = 4
local CMD_DEVICE_ITEM_RX      = 5
local CMD_PARAM_REQUEST_LIST  = 6
local CMD_PARAM_ITEM          = 7
local CMD_PARAM_ITEM2         = 8
local CMD_PARAM_ITEM3         = 9
local CMD_REQUEST_CMD         = 10
local CMD_INFO                = 11
local CMD_PARAM_SET           = 12
local CMD_PARAM_STORE         = 13
local CMD_BIND_START          = 14
local CMD_BIND_STOP           = 15
local CMD_MODELID_SET         = 16
local CMD_SYSTEM_BOOTLOADER   = 17

-- types
local T_UINT8, T_INT8, T_UINT16, T_INT16, T_LIST, T_STR6 = 
  M.TYPES.UINT8, M.TYPES.INT8, M.TYPES.UINT16, M.TYPES.INT16, M.TYPES.LIST, M.TYPES.STR6

local function now() return os.clock() end

-- ---------- sensor wrapper ----------
local function makeSensor()
  if crsf and crsf.getSensor then
    return crsf.getSensor()
  end
  return {
    popFrame  = function(_, id) return crsf.popFrame(id) end,
    pushFrame = function(_, id, data) return crsf.pushFrame(id, data) end,
  }
end

local function drainFrames(sensor, max)
  max = max or 64
  for _ = 1, max do
    local cmd = sensor:popFrame(130)
    if not cmd then break end
  end
end

-- ---------- bit helpers (Ethos-friendly) ----------
local function band(a, b) return (a or 0) & (b or 0) end
local function rshift(a, n) return (a or 0) >> (n or 0) end
local function lshift(a, n) return (a or 0) << (n or 0) end
local function btest(mask, bits) return band(bits, mask) ~= 0 end

-- Optimized popcount using a simple lookup for nibbles to reduce iterations
local NIBBLE_LOOKUP = { [0]=0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4 }
local function popcount16(x)
  x = x or 0
  return NIBBLE_LOOKUP[x & 0xF] + 
         NIBBLE_LOOKUP[(x >> 4) & 0xF] + 
         NIBBLE_LOOKUP[(x >> 8) & 0xF] + 
         NIBBLE_LOOKUP[(x >> 12) & 0xF]
end

local function versionToInt(v)
  local major = (v & 0xF000) >> 12
  local minor = (v & 0x0FC0) >> 6
  local patch = (v & 0x003F)
  return major * 10000 + minor * 100 + patch
end

local function versionToStr(v)
  local major = (v & 0xF000) >> 12
  local minor = (v & 0x0FC0) >> 6
  local patch = (v & 0x003F)
  return string.format("v%d.%d.%02d", major, minor, patch)
end

local function allowed_mask_editable(mask)
  -- same intent as the script: if none or only one option allowed -> not editable
  if not mask or mask == 0 then return false end
  return popcount16(mask) > 1
end

-- ---------- payload helpers (0-based offsets) ----------
-- These now take 'payload' (the raw data table) and 'base' (the offset to payload start)
local function u8(p, base, ofs0) return (p[base + ofs0 + 1] or 0) & 0xFF end
local function i8(p, base, ofs0)
  local v = u8(p, base, ofs0)
  if v >= 128 then v = v - 256 end
  return v
end
local function u16(p, base, ofs0) return u8(p, base, ofs0) + (u8(p, base, ofs0 + 1) << 8) end
local function i16(p, base, ofs0)
  local v = u16(p, base, ofs0)
  if v >= 32768 then v = v - 65536 end
  return v
end

local function mb_str(p, base, ofs0, n)
  local s = {}
  for k = 0, n - 1 do
    local b = p[base + ofs0 + 1 + k]
    if not b or b == 0 then break end
    s[#s + 1] = string.char(b)
  end
  return table.concat(s)
end

local function mb_value_by_type(p, base, ofs0, paramType)
  if paramType == T_UINT8 then return u8(p, base, ofs0) end
  if paramType == T_INT8 then return i8(p, base, ofs0) end
  if paramType == T_UINT16 then return u16(p, base, ofs0) end
  if paramType == T_INT16 then return i16(p, base, ofs0) end
  if paramType == T_LIST then return u8(p, base, ofs0) end
  return u8(p, base, ofs0)
end

local function mb_value_or_str6(p, base, ofs0, paramType)
  if paramType == T_STR6 then
    return mb_str(p, base, ofs0, 6)
  end
  return mb_value_by_type(p, base, ofs0, paramType)
end

local function bytes_to_string(bytes)
  local s = {}
  for i = 1, #bytes do
    local b = bytes[i]
    if not b or b == 0 then break end
    s[#s + 1] = string.char(b)
  end
  return table.concat(s)
end

local function split_csv(str)
  local opts = {}
  if not str or str == "" then return opts end
  for part in string.gmatch(str .. ",", "([^,]+)") do
    part = part:match("^%s*(.-)%s*$")
    if part ~= "" then opts[#opts + 1] = part end
  end
  return opts
end

local function take_bytes(p, base, ofs0, len)
  local out = {}
  for i = 0, len - 1 do
    out[#out + 1] = u8(p, base, ofs0 + i)
  end
  return out
end

local function segment_is_full(p, base, ofs0, len)
  for i = 0, len - 1 do
    if u8(p, base, ofs0 + i) == 0 then return false end
  end
  return true
end

-- ---------- command lengths ----------
local function cmd_len(cmd)
  if cmd == CMD_TX_LINK_STATS then return 22 end
  if cmd == CMD_DEVICE_ITEM_TX or cmd == CMD_DEVICE_ITEM_RX then return 24 end
  if cmd == CMD_PARAM_ITEM or cmd == CMD_PARAM_ITEM2 or cmd == CMD_PARAM_ITEM3 then return 24 end
  if cmd == CMD_REQUEST_CMD then return 18 end
  if cmd == CMD_INFO then return 24 end
  if cmd == CMD_PARAM_SET then return 7 end
  if cmd == CMD_MODELID_SET then return 3 end
  return 0
end

-- Pre-allocate a buffer for pushMB to avoid table churn
local PUSH_BUFFER = { string.byte("O"), string.byte("W"), 0 }
local function pushMB(sensor, cmd, payload)
  PUSH_BUFFER[3] = A0 + cmd
  local need = cmd_len(cmd)
  -- Clear buffer from 4 to 3+need
  for i = 4, 3 + need do PUSH_BUFFER[i] = 0 end
  -- Copy payload
  for i = 1, #payload do PUSH_BUFFER[3 + i] = payload[i] end
  -- If we need to truncate the buffer for pushFrame, we might still have churn 
  -- if Ethos doesn't support a length parameter. But many Ethos versions copy the table anyway.
  -- We'll assume for now we should only send the relevant part if possible.
  -- To be safest and most efficient, we reuse as much as we can.
  local framesize = 3 + need
  if #PUSH_BUFFER > framesize then
    for i = #PUSH_BUFFER, framesize + 1, -1 do PUSH_BUFFER[i] = nil end
  end
  return sensor:pushFrame(129, PUSH_BUFFER)
end

-- ---------- internal model ----------
local function newModel()
  return {
    gotInfo = false,

    txItem = nil,
    rxItem = nil,
    info = nil,

    params = {},               -- [idx1] = param
    paramsComplete = false,

    lastParamRxAt = nil,
    lastRxAt = nil,

    lastInfoReqAt = nil,
    lastDeviceReqAt = nil,
    lastListReqAt = nil,
    lastIndexReqAt = nil,
    lastRequestedIndex = nil,
  }
end

local function ensureParam(model, idx0)
  local idx1 = idx0 + 1
  local p = model.params[idx1]
  if not p then
    p = {
      idx0 = idx0,
      -- enrichment state
      _gotItem = false,
      _gotItem2 = false,
      _needItem3 = false,
      _gotItem3 = false,
      _needItem4 = false,
      _gotItem4 = false,
      _optBytes = nil,
    }
    model.params[idx1] = p
  end
  return p
end

-- ---------- decode DEVICE_ITEM_TX/RX ----------
local function decode_device_item(data, base)
  local version_u16 = u16(data, base, 0)
  local setuplayout_u16 = u16(data, base, 2)
  local name = mb_str(data, base, 4, 20)

  return {
    version_u16 = version_u16,
    setuplayout_u16 = setuplayout_u16,
    name = name,
    version_int = versionToInt(version_u16),
    version_str = versionToStr(version_u16),
    setuplayout_int = versionToInt(setuplayout_u16),
  }
end

-- ---------- decode INFO ----------
local function decode_info(data, base)
  local receiver_sensitivity = i16(data, base, 0)
  local flags2 = u8(data, base, 2)
  local tx_power_dbm = i8(data, base, 3)
  local rx_power_dbm = i8(data, base, 4)
  local flags5 = u8(data, base, 5)
  local tx_config_id = u8(data, base, 6)
  local div = u8(data, base, 7)

  return {
    receiver_sensitivity = receiver_sensitivity,
    has_status = (flags2 & 0x01) ~= 0 and 1 or 0,
    binding = (flags2 & 0x02) ~= 0 and 1 or 0,
    tx_power_dbm = tx_power_dbm,
    rx_power_dbm = rx_power_dbm,
    rx_available = (flags5 & 0x01) ~= 0 and 1 or 0,
    tx_config_id = tx_config_id,
    tx_diversity = div & 0x0F,
    rx_diversity = (div >> 4) & 0x0F,
  }
end

-- ---------- decode PARAM items ----------
local function on_PARAM_ITEM(model, data, base)
  local idx0 = data[base + 1] -- maps to original payload[1]
  if idx0 == nil then return end
  model.lastParamRxAt = now()

  if idx0 == 255 then
    model.paramsComplete = true
    return
  end

  local p = ensureParam(model, idx0)
  p.paramType = u8(data, base, 1)
  p.name = mb_str(data, base, 2, 16)
  p.value = mb_value_or_str6(data, base, 18, p.paramType)

  if not p._gotItem then
    p.min = p.min or 0
    p.max = p.max or 0
    p.unit = p.unit or ""
    p.options = p.options or {}
    p.allowed_mask = p.allowed_mask or 0
    if p.editable == nil then p.editable = true end
    p._gotItem = true
  end
end

local function finalize_list_options(p)
  if not p._optBytes then return end
  local s = bytes_to_string(p._optBytes)
  p.options = split_csv(s)
  p.min = 0
  p.max = math.max(#p.options - 1, 0)
end

local function on_PARAM_ITEM2(model, data, base)
  local idx0 = data[base + 1]
  if idx0 == nil or idx0 == 255 then return end
  model.lastParamRxAt = now()

  local p = model.params[idx0 + 1]
  if not p then return end

  if p.paramType ~= nil and p.paramType < T_LIST then
    p.min = mb_value_by_type(data, base, 1, p.paramType)
    p.max = mb_value_by_type(data, base, 3, p.paramType)
    p.unit = mb_str(data, base, 7, 6)
    p._gotItem2 = true
    return
  end

  if p.paramType == T_LIST then
    p.allowed_mask = u16(data, base, 1)
    p.editable = allowed_mask_editable(p.allowed_mask)

    p._optBytes = p._optBytes or {}
    local chunk = take_bytes(data, base, 3, 21)
    for i = 1, #chunk do p._optBytes[#p._optBytes + 1] = chunk[i] end
    finalize_list_options(p)

    p._needItem3 = segment_is_full(data, base, 3, 21)
    p._gotItem2 = true

    if not p._needItem3 then
      p._gotItem3, p._needItem4, p._gotItem4 = false, false, false
    end
  end
end

local function on_PARAM_ITEM3(model, data, base)
  local rawIndex = data[base + 1]
  if rawIndex == nil then return end
  model.lastParamRxAt = now()

  local is_item4 = false
  local idx0 = rawIndex
  if idx0 >= 128 then
    idx0 = idx0 - 128
    is_item4 = true
  end

  local p = model.params[idx0 + 1]
  if not p or p.paramType ~= T_LIST then return end

  p._optBytes = p._optBytes or {}
  local chunk = take_bytes(data, base, 1, 23)
  for i = 1, #chunk do p._optBytes[#p._optBytes + 1] = chunk[i] end
  finalize_list_options(p)

  if not is_item4 then
    p._gotItem3 = true
    p._needItem4 = segment_is_full(data, base, 1, 23)
  else
    p._gotItem4 = true
    p._needItem4 = false
  end
end

local function param_is_ready(p, full)
  if not p or not p._gotItem then return false end
  if not full then return true end

  if p.paramType ~= nil and p.paramType < T_LIST then
    return p._gotItem2
  end
  if p.paramType == T_LIST then
    if not p._gotItem2 then return false end
    if p._needItem3 and not p._gotItem3 then return false end
    if p._needItem4 and not p._gotItem4 then return false end
    return true
  end
  if p.paramType == T_STR6 then return true end
  return true
end

-- ---------- frame handler ----------
local function handleFrame(model, cmd, data)
  if cmd ~= 130 or not data or #data < 2 then return end
  local mcmd = data[1] - A0
  local base = 1 -- MBridge payload starts at data[2]
  model.lastRxAt = now()

  if mcmd == CMD_DEVICE_ITEM_TX then
    model.txItem = decode_device_item(data, base)
  elseif mcmd == CMD_DEVICE_ITEM_RX then
    model.rxItem = decode_device_item(data, base)
  elseif mcmd == CMD_INFO then
    model.info = decode_info(data, base)
    model.gotInfo = true
  elseif mcmd == CMD_PARAM_ITEM then
    on_PARAM_ITEM(model, data, base)
  elseif mcmd == CMD_PARAM_ITEM2 then
    on_PARAM_ITEM2(model, data, base)
  elseif mcmd == CMD_PARAM_ITEM3 then
    on_PARAM_ITEM3(model, data, base)
  end
end

-- ---------- queue ----------
local function finish(req, ok, dataOrErr)
  req.done = true
  if req.cb then
    if ok then req.cb({ ok = true, type = req.type, data = dataOrErr })
    else req.cb({ ok = false, type = req.type, err = dataOrErr }) end
  end
end

local function activeReq(self)
  local q = self.queue
  for i = 1, #q do
    if not q[i].done then return q[i] end
  end
  return nil
end

local function enqueue(self, req)
  req.id = self.nextReqId
  self.nextReqId = self.nextReqId + 1
  self.queue[#self.queue + 1] = req
  return req.id
end

local function pruneQueue(self)
  local q = self.queue
  local n = #q
  if n == 0 then return end
  local writeIdx = 1
  for readIdx = 1, n do
    if not q[readIdx].done then
      if writeIdx ~= readIdx then q[writeIdx] = q[readIdx] end
      writeIdx = writeIdx + 1
    end
  end
  for i = writeIdx, n do q[i] = nil end
end

-- ---------- public API ----------
function M.new(opts)
  local self = {
    sensor = makeSensor(),
    model = newModel(),
    queue = {},
    nextReqId = 1,
    settleS = (opts and opts.settleS) or DEFAULTS.SETTLE_S,
    createdAt = now(),
    strategy = (opts and opts.strategy) or "by_index",
    saveDeadS = (opts and opts.saveDeadS) or DEFAULTS.SAVE_DEAD_S,
    lastStoreAt = nil,
  }

  drainFrames(self.sensor)
  setmetatable(self, { __index = M })
  return self
end

function M.reset(self)
  self.model = newModel()
  self.queue = {}
  self.createdAt = now()
  self.lastStoreAt = nil
  drainFrames(self.sensor)
end

function M.getInfo(self, cb)
  return enqueue(self, { type = "GET_INFO", cb = cb, deadline = now() + DEFAULTS.DEADLINE_MEDIUM_S })
end

function M.refreshInfo(self, cb)
  -- force a fresh INFO request by clearing the gotInfo flag
  self.model.gotInfo = false
  return enqueue(self, { type = "GET_INFO", cb = cb, deadline = now() + DEFAULTS.DEADLINE_MEDIUM_S })
end

function M.getDeviceItems(self, cb)
  return enqueue(self, { type = "GET_DEVICE_ITEMS", cb = cb, deadline = now() + DEFAULTS.DEADLINE_MEDIUM_S })
end

function M.refreshRxItem(self, cb)
  -- force a fresh request for RX device item by clearing cached value
  self.model.rxItem = nil
  return enqueue(self, { type = "GET_RX_ITEM", cb = cb, deadline = now() + DEFAULTS.DEADLINE_MEDIUM_S })
end

function M.getAllParams(self, cb, opts)
  opts = opts or {}
  return enqueue(self, {
    type = "GET_ALL_PARAMS",
    cb = cb,
    deadline = now() + (opts.deadlineS or DEFAULTS.DEADLINE_LONG_S),
    full = (opts.full ~= false),
    skipRx = opts.skipRx or false,
  })
end

function M.getParam(self, idx0, cb, opts)
  opts = opts or {}
  return enqueue(self, {
    type = "GET_PARAM",
    idx0 = idx0,
    cb = cb,
    deadline = now() + (opts.deadlineS or DEFAULTS.DEADLINE_PARAM_S),
    full = (opts.full ~= false),
  })
end

function M.setParam(self, idx0, value, cb)
  return enqueue(self, { type = "SET_PARAM", idx0 = idx0, value = value, cb = cb, deadline = now() + DEFAULTS.DEADLINE_SHORT_S })
end

function M.store(self, cb)
  return enqueue(self, { type = "STORE", cb = cb, deadline = now() + DEFAULTS.DEADLINE_LONG_S })
end

function M.bindStart(self, cb)
  return enqueue(self, { type = "BIND_START", cb = cb, deadline = now() + DEFAULTS.DEADLINE_SHORT_S })
end

function M.bindStop(self, cb)
  return enqueue(self, { type = "BIND_STOP", cb = cb, deadline = now() + DEFAULTS.DEADLINE_SHORT_S })
end

function M.bootloader(self, cb)
  return enqueue(self, { type = "BOOT", cb = cb, deadline = now() + DEFAULTS.DEADLINE_SHORT_S })
end

-- ---------- request primitives ----------
local function maybeRequestInfo(self)
  local m = self.model
  local t = now()
  if m.gotInfo then return end
  if (not m.lastInfoReqAt) or (t - m.lastInfoReqAt > DEFAULTS.REQ_INTERVAL_INFO_S) then
    pushMB(self.sensor, CMD_REQUEST_INFO, {})
    m.lastInfoReqAt = t
  end
end

local function maybeRequestDeviceItems(self)
  local m = self.model
  local t = now()
  if m.txItem and m.rxItem then return end
  if (not m.lastDeviceReqAt) or (t - m.lastDeviceReqAt > DEFAULTS.REQ_INTERVAL_INFO_S) then
    pushMB(self.sensor, CMD_REQUEST_INFO, {})
    m.lastDeviceReqAt = t
  end
end

local function requestParamList(self)
  local m = self.model
  local t = now()
  if (not m.lastListReqAt) or (t - m.lastListReqAt > DEFAULTS.REQ_INTERVAL_LIST_S) then
    m.paramsComplete = false
    pushMB(self.sensor, CMD_PARAM_REQUEST_LIST, {})
    m.lastListReqAt = t
  end
end

local function requestParamByIndex(self, idx0)
  local m = self.model
  local t = now()
  if (m.lastRequestedIndex ~= idx0) or (not m.lastIndexReqAt) or (t - m.lastIndexReqAt > DEFAULTS.REQ_INTERVAL_INDEX_S) then
    pushMB(self.sensor, CMD_REQUEST_CMD, { CMD_PARAM_ITEM, idx0 & 0xFF })
    m.lastIndexReqAt = t
    m.lastRequestedIndex = idx0
  end
end

-- ---------- pump ----------
function M.processQueue(self)
  local t = now()
  if (t - self.createdAt) < self.settleS then return end

  while true do
    local cmd, data = self.sensor:popFrame(130)
    if not cmd then break end
    handleFrame(self.model, cmd, data)
  end

  local req = activeReq(self)
  if not req then
    if #self.queue > 0 then pruneQueue(self) end
    return
  end

  if t > (req.deadline or 0) then
    finish(req, false, "timeout")
    return
  end

  if self.lastStoreAt and (t - self.lastStoreAt) < self.saveDeadS then
    return
  end

  local m = self.model
  if req.type == "GET_INFO" then
    if m.gotInfo and m.info then
      finish(req, true, { info = m.info })
    else
      maybeRequestInfo(self)
    end
    return
  end

  if req.type == "GET_DEVICE_ITEMS" then
    if m.txItem then
      finish(req, true, { tx = m.txItem, rx = m.rxItem, info = m.info })
    else
      maybeRequestDeviceItems(self)
      maybeRequestInfo(self)
    end
    return
  end

  if req.type == "GET_RX_ITEM" then
    if m.rxItem then
      finish(req, true, { rx = m.rxItem })
    else
      maybeRequestDeviceItems(self)
    end
    return
  end

  if not m.gotInfo then
    maybeRequestInfo(self)
    return
  end

  if req.type == "SET_PARAM" then
    if not req.sent then
      local payload
      if type(req.value) == "string" then
        payload = { req.idx0 & 0xFF }
        local s = tostring(req.value or "")
        for i = 1, 6 do
          local b = string.byte(s, i) or 0
          payload[#payload + 1] = b & 0xFF
        end
      else
        payload = { req.idx0 & 0xFF, (req.value or 0) & 0xFF }
      end
      pushMB(self.sensor, CMD_PARAM_SET, payload)
      req.sent = true
      finish(req, true, { sent = true })
    end
    return
  end

  if req.type == "STORE" then
    if not req.sent then
      pushMB(self.sensor, CMD_PARAM_STORE, {})
      req.sent = true
      self.lastStoreAt = t
      finish(req, true, { sent = true })
    end
    return
  end

  if req.type == "BIND_START" then
    if not req.sent then
      pushMB(self.sensor, CMD_BIND_START, {})
      req.sent = true
      finish(req, true, { sent = true })
    end
    return
  end

  if req.type == "BIND_STOP" then
    if not req.sent then
      pushMB(self.sensor, CMD_BIND_STOP, {})
      req.sent = true
      finish(req, true, { sent = true })
    end
    return
  end

  if req.type == "BOOT" then
    if not req.sent then
      pushMB(self.sensor, CMD_SYSTEM_BOOTLOADER, {})
      req.sent = true
      finish(req, true, { sent = true })
    end
    return
  end

  if req.type == "GET_PARAM" then
    local p = m.params[(req.idx0 or 0) + 1]
    if param_is_ready(p, req.full) then
      finish(req, true, { param = p })
      return
    end

    if self.strategy == "by_index" then
      requestParamByIndex(self, req.idx0 or 0)
    else
      if not req.streamStarted then
        req.streamStarted = true
        requestParamList(self)
      end
    end
    return
  end

  if req.type == "GET_ALL_PARAMS" then
    if req.nextIdx0 == nil then
      req.nextIdx0 = 0
      -- If we are now asking for RX but previously skipped them, 
      -- we MUST reset paramsComplete to allow a re-scan.
      if not req.skipRx then m.paramsComplete = false end
    end

    if m.paramsComplete then
      finish(req, true, { params = m.params, complete = true })
      return
    end

    if self.strategy == "by_index" then
      -- Search pass
      while true do
        local p = m.params[req.nextIdx0 + 1]
        
        -- If we don't have the base item yet, we must stop and request
        if not (p and p._gotItem) then break end

        local isRx = (p.name:sub(1, 3) == "Rx ")
        
        if req.skipRx and isRx then
          p._skipped = true
          req.nextIdx0 = req.nextIdx0 + 1
        elseif not req.skipRx and p._skipped then
          -- We want RX now, but this one was previously skipped.
          -- Check if it's already "full" (unlikely if skipped) or needs fetch.
          if param_is_ready(p, req.full) then
            p._skipped = false
            req.nextIdx0 = req.nextIdx0 + 1
          else
            break
          end
        else
          -- Check if current state meets request (full vs partial)
          if param_is_ready(p, req.full) then
            req.nextIdx0 = req.nextIdx0 + 1
          else
            break
          end
        end

        if req.nextIdx0 > 255 then
          m.paramsComplete = true
          finish(req, true, { params = m.params, complete = true })
          return
        end
      end

      requestParamByIndex(self, req.nextIdx0)
    else
      requestParamList(self)
    end
    return
  end
end

return M
