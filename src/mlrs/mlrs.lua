--[[
================================================================================
mLRS Lua API (UI-free)
================================================================================

Purpose
-------
This module implements a UI-independent mLRS protocol client for Ethos
(1.6 / 1.7 compatible). It:
  - Requests INFO and PARAMETER LIST data from the mLRS module
  - Decodes PARAM_ITEM / PARAM_ITEM2 / PARAM_ITEM3 frames
  - Normalizes LIST options (including ITEM3 continuation + CSV fallback)
  - Exposes a small non-blocking API suitable for use from a system tool,
    MLRS module, or any UI layer.

This file contains NO UI code and NO Ethos registration.
It is intended to be driven by main.lua (or another controller).


Architecture
------------
Ethos wakeup() MUST remain non-blocking.
This module therefore uses a request / process / poll pattern.

  main.lua:
    - owns lifecycle (init / wakeup / close)
    - decides when to start a fetch
    - consumes the resulting data structure

  mlrs.lua:
    - owns protocol state
    - owns CRSF vendor frame decoding
    - returns a fully structured parameter table


Public API
----------

1) Create a context (once per tool/module open)

    local mlrs = require("mlrs")
    local ctx  = mlrs.createContext()

    -- ctx = {
    --   sensor = CRSF sensor handle,
    --   st     = internal protocol state
    -- }


2) Start a single fetch (non-blocking)

    mlrs.request(ctx, {
      timeout = 12.0,   -- seconds (optional, default 10)
      settle  = 1.5     -- seconds to wait before first request (optional)
    })


3) Drive the protocol engine (every wakeup)

    mlrs.process(ctx)

    -- This pumps RX frames, sends INFO / PARAM requests,
    -- and advances internal state. It must be called
    -- repeatedly until poll() reports completion.


4) Check for completion and retrieve data

    local done, data, err = mlrs.poll(ctx)

    if done and data then
      -- SUCCESS
    elseif done and err then
      -- ERROR (e.g. "timeout")
    end


Returned Data Structure
-----------------------

On success, poll() returns:

  data = {
    ok = true,

    info = {
      tx = {
        name = "<string>",
        s1   = "<string>",
        raw  = { <bytes> }
      },
      rx = {
        name = "<string>",
        s1   = "<string>",
        raw  = { <bytes> }
      },
      info = {
        name = "<string>",
        s1   = "<string>",
        raw  = { <bytes> }
      },
      raw = {
        { which="tx",   payload={...} },
        { which="rx",   payload={...} },
        { which="info", payload={...} },
      }
    },

    params = {
      {
        index0  = 0,               -- parameter index (0-based)
        name    = "Power",
        typ     = 4,               -- LIST / UINT8 / INT16 etc
        value   = 2,               -- current value
        min     = 0,
        max     = 4,
        unit    = "mW",            -- nil for LIST
        options = {                -- LIST only
          "10mW", "25mW", "100mW"
        }
      },
      ...
    },

    meta = {
      rxAny        = <number>,     -- total frames seen
      rxVendor130  = <number>,     -- CRSF vendor frames seen
      startedAt    = <os.clock>,
      finishedAt   = <os.clock>
    }
  }


Lifecycle Notes
---------------
- This module never blocks.
- request() must be called explicitly (or via an auto-start wrapper).
- process() MUST be called repeatedly (typically from wakeup()).
- poll() is safe to call every wakeup; it only returns "done" once.
- After completion, the context remains valid for inspection.
- To re-fetch, call request() again.


================================================================================
]]


local M = {}

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

local T_UINT8, T_INT8, T_UINT16, T_INT16, T_LIST, T_STR6 = 0, 1, 2, 3, 4, 5

------------------------------
-- Helpers
------------------------------
local function band7(b) return (b or 0) & 0x7F end
local function u8(p, i) return (p[i + 1] or 0) & 0xFF end
local function i8(p, i) local v=u8(p,i); if v>127 then v=v-256 end; return v end
local function u16(p, i) return (u8(p, i) << 8) + u8(p, i + 1) end
local function i16(p, i) local v=u16(p,i); if v>32767 then v=v-65536 end; return v end

local function mb_str(p, i, n)
  local s = {}
  for k = 0, n - 1 do
    local b = p[i + 1 + k]
    if not b or b == 0 then break end
    s[#s + 1] = string.char(band7(b))
  end
  return table.concat(s)
end

local function mb_value_by_type(p, i, typ)
  if     typ == T_UINT8  then return u8(p, i), 1
  elseif typ == T_INT8   then return i8(p, i), 1
  elseif typ == T_UINT16 then return u16(p, i), 2
  elseif typ == T_INT16  then return i16(p, i), 2
  elseif typ == T_STR6   then return mb_str(p, i, 6), 6
  end
  return 0, 0
end


-- Encode a value into the fixed-width (6-byte) value field used by CMD_PARAM_SET.
-- Format: { idx0, v0, v1, v2, v3, v4, v5 } where v0..v5 are payload bytes.
local function mb_encode_set_payload(field, newValue)
  local idx0 = field.index0 or 0
  local typ = field.typ

  local b = { idx0 }

  local function pad(n)
    for _ = 1, n do b[#b + 1] = 0 end
  end

  if typ == T_LIST then
    b[#b + 1] = band7(tonumber(newValue) or 0)
    pad(5)

  elseif typ == T_UINT8 then
    b[#b + 1] = (tonumber(newValue) or 0) & 0xFF
    pad(5)

  elseif typ == T_INT8 then
    local v = tonumber(newValue) or 0
    if v < 0 then v = 256 + (v % 256) end
    b[#b + 1] = v & 0xFF
    pad(5)

  elseif typ == T_UINT16 then
    local v = tonumber(newValue) or 0
    b[#b + 1] = v & 0xFF
    b[#b + 1] = (v >> 8) & 0xFF
    pad(4)

  elseif typ == T_INT16 then
    local v = tonumber(newValue) or 0
    if v < 0 then v = 65536 + (v % 65536) end
    b[#b + 1] = v & 0xFF
    b[#b + 1] = (v >> 8) & 0xFF
    pad(4)

  elseif typ == T_STR6 then
    local s = tostring(newValue or "")
    -- strip any trailing NULs coming from UI layers
    s = s:gsub("%z+$", "")
    for i = 1, 6 do
      b[#b + 1] = string.byte(s, i) or 0
    end

  else
    -- Unknown/unsupported; send zeroed value field.
    pad(6)
  end

  -- Ensure exactly 7 bytes total
  while #b < 7 do b[#b + 1] = 0 end
  if #b > 7 then
    local t = { b[1] }
    for i = 2, 7 do t[i] = b[i] end
    b = t
  end

  return b
end

local function cmd_len(cmd)
  if cmd == CMD_PARAM_ITEM or cmd == CMD_PARAM_ITEM2 or cmd == CMD_PARAM_ITEM3 then return 24 end
  if cmd == CMD_DEVICE_ITEM_TX or cmd == CMD_DEVICE_ITEM_RX then return 24 end
  if cmd == CMD_INFO then return 24 end
  if cmd == CMD_PARAM_SET then return 7 end
  if cmd == CMD_PARAM_STORE then return 0 end
  return 0
end

local function pushMB(sensor, cmd, payload)
  local data = { string.byte('O'), string.byte('W'), A0 + cmd }
  local need = cmd_len(cmd)
  for _ = 1, need do data[#data + 1] = 0 end
  for i = 1, #payload do data[3 + i] = payload[i] end
  return sensor:pushFrame(129, data)
end

local function payload_from_vendor(data)
  local payload = {}
  for i = 2, #data do payload[#payload + 1] = data[i] end
  return payload
end

------------------------------
-- State
------------------------------
local function newState()
  return {
    haveInfo = false,
    paramsComplete = false,

    -- write pipeline
    txq = {},
    pendingTx = nil,

    enteredAt = nil,
    lastInfoReq = nil,
    lastParamsReq = nil,
    lastRxAt = nil,

    info = { tx = nil, rx = nil, info = nil, raw = {} },
    fields = {},
    _optChunks = {},

    rxAny = 0,
    rxVendor130 = 0,

    fetch = {
      active = false,
      done = false,
      err = nil,
      startedAt = nil,
      timeout = 10.0,
    },

    -- optional “auto-start” policy (main.lua can ignore this)
    auto = {
      enabled = false,
      started = false,
      opts = { timeout = 12.0, settle = 1.5 }
    }
  }
end

local function resetForFetch(st, opts)
  st.haveInfo = false
  st.paramsComplete = false
  st.lastInfoReq = nil
  st.lastParamsReq = nil
  st.lastRxAt = nil

  st.info = { tx = nil, rx = nil, info = nil, raw = {} }
  st.fields = {}
  st._optChunks = {}

  st.fetch.active = true
  st.fetch.done = false
  st.fetch.err = nil
  st.fetch.startedAt = os.clock()

  st.fetch.timeout = tonumber(opts.timeout) or 10.0
  st.enteredAt = os.clock()
  st._settle = tonumber(opts.settle) or 1.5
end

------------------------------
-- Decoders
------------------------------
local function ensureField(st, idx0)
  local k = (idx0 or 0) + 1
  st.fields[k] = st.fields[k] or { index0 = idx0, id = k }
  return st.fields[k]
end

local function decode_INFO_like(st, which, payload)
  local entry = {
    raw = payload,
    name = mb_str(payload, 0, 16),
    s1   = mb_str(payload, 16, 8),
  }
  st.info.raw[#st.info.raw + 1] = { which = which, payload = payload }
  if which == "tx" then st.info.tx = entry end
  if which == "rx" then st.info.rx = entry end
  if which == "info" then st.info.info = entry end
  st.haveInfo = true
end

local function on_PARAM_ITEM(st, payload)
  local idx = payload[1] or 255
  if idx == 255 then st.paramsComplete = true; return end

  local f = ensureField(st, idx)
  f.typ  = u8(payload, 1)
  f.name = mb_str(payload, 2, 16)

  if f.typ == T_LIST then
    f.value = band7(u8(payload, 18) or 0)
    f.options = f.options or {}
  else
    f.value = select(1, mb_value_by_type(payload, 18, f.typ))
  end

  -- If a write is in-flight, treat an update for the same index as an ACK.
  if st.pendingTx and st.pendingTx.kind == 'set' and st.pendingTx.idx0 == idx then
    st.pendingTx.acked = true
  end
end

local function append_option_chunk(st, idx0, payload, startOfs, endOfs)
  local k = (idx0 or 0) + 1
  st._optChunks[k] = st._optChunks[k] or {}
  local buf = st._optChunks[k]
  for ofs = startOfs, endOfs do
    local b = payload[ofs]
    if b == nil then break end
    buf[#buf + 1] = b
  end
end

local function finalize_options_from_chunks(st, idx0)
  local k = (idx0 or 0) + 1
  local bytes = st._optChunks[k]
  if not bytes or #bytes == 0 then return {} end

  local opts, cur = {}, {}
  for _, b in ipairs(bytes) do
    if b == 0 then
      if #cur > 0 then
        opts[#opts + 1] = table.concat(cur)
        cur = {}
      end
    else
      cur[#cur + 1] = string.char(band7(b))
    end
  end
  if #cur > 0 then opts[#opts + 1] = table.concat(cur) end

  if #opts == 1 and opts[1]:find(",") then
    local parts = {}
    for part in string.gmatch(opts[1], "([^,]+)") do
      parts[#parts + 1] = (part:gsub("%z", "")):match("^%s*(.-)%s*$")
    end
    opts = parts
  end

  return opts
end

local function on_PARAM_ITEM2(st, payload)
  local idx0 = payload[1]
  if idx0 == nil then return end
  local f = ensureField(st, idx0)

  if f.typ == T_LIST then
    append_option_chunk(st, idx0, payload, 2, 23)
    f.options = finalize_options_from_chunks(st, idx0)
    f.min, f.max = 0, math.max(#(f.options or {}) - 1, 0)
    if type(f.value) == "number" and f.value > f.max then f.value = f.max end
  else
    f.min = select(1, mb_value_by_type(payload, 1, f.typ))
    f.max = select(1, mb_value_by_type(payload, 3, f.typ))
    f.unit = mb_str(payload, 7, 6)
  end
end

local function on_PARAM_ITEM3(st, payload)
  local idx0 = payload[1]
  if idx0 == nil then return end
  local f = st.fields[idx0 + 1]
  if not f then return end

  if f.typ == T_LIST then
    append_option_chunk(st, idx0, payload, 2, 23)
    f.options = finalize_options_from_chunks(st, idx0)
    f.min, f.max = 0, math.max(#(f.options or {}) - 1, 0)
    if type(f.value) == "number" and f.value > f.max then f.value = f.max end
  end
end

------------------------------
-- Public API
------------------------------
function M.createContext()
  local st = newState()

  local sensor
  if crsf and crsf.getSensor then
    sensor = crsf.getSensor()
  else
    sensor = {
      popFrame = function(self) return crsf.popFrame() end,
      pushFrame = function(self, id, data) return crsf.pushFrame(id, data) end
    }
  end

  return { sensor = sensor, st = st }
end


-- Queue a parameter write (CMD_PARAM_SET).
-- You must have fetched parameters at least once so the type is known.
-- Returns: true on queue, or false, err.
function M.queueSet(ctx, idx0, newValue, opts)
  if not (ctx and ctx.st) then return false, "no ctx" end
  local st = ctx.st
  local f = st.fields and st.fields[(idx0 or 0) + 1]
  if not f or f.typ == nil then return false, "unknown field (fetch first)" end

  local payload = mb_encode_set_payload(f, newValue)
  st.txq[#st.txq + 1] = {
    cmd = CMD_PARAM_SET,
    idx0 = idx0,
    payload = payload,
    maxRetries = (opts and opts.maxRetries) or 2,
    retryAfter = (opts and opts.retryAfter) or 0.6,
  }
  return true
end

-- Queue a store-to-flash/eeprom (CMD_PARAM_STORE).
function M.queueStore(ctx, opts)
  if not (ctx and ctx.st) then return false, "no ctx" end
  local st = ctx.st
  st.txq[#st.txq + 1] = {
    cmd = CMD_PARAM_STORE,
    settleAfter = (opts and opts.settleAfter) or 0.3,
  }
  return true
end

-- True if a write is currently pending or queued.
function M.isWriteBusy(ctx)
  if not (ctx and ctx.st) then return false end
  local st = ctx.st
  return (st.pendingTx ~= nil) or (st.txq and #st.txq > 0)
end

function M.setAutoRequest(ctx, opts)
  local st = ctx.st
  st.auto.enabled = true
  st.auto.started = false
  if opts then st.auto.opts = opts end
end

function M.request(ctx, opts)
  opts = opts or {}
  resetForFetch(ctx.st, opts)
end

-- One “tick”: pump RX, send next request(s) if needed, update done/timeout
function M.process(ctx)
  local st = ctx.st
  local now = os.clock()

  -- optional auto-start policy
  if st.auto.enabled and not st.auto.started then
    st.auto.started = true
    M.request(ctx, st.auto.opts)
  end

  -- reacquire sensor if needed
  if (not ctx.sensor or not ctx.sensor.pushFrame) and crsf and crsf.getSensor then
    ctx.sensor = crsf.getSensor()
  end

  if not st.fetch.active then
    return
  end

  -- settle window
  if st.enteredAt and (now - st.enteredAt) < (st._settle or 0) then
    return
  end

  -- RX pump
  for _ = 1, 128 do
    local cmd, data = ctx.sensor:popFrame()
    if not cmd then break end
    st.rxAny = st.rxAny + 1
    st.lastRxAt = now

    if cmd == 130 and data and data[1] then
      st.rxVendor130 = st.rxVendor130 + 1
      local mcmd = data[1] - A0
      local payload = payload_from_vendor(data)

      if mcmd == CMD_DEVICE_ITEM_TX then
        decode_INFO_like(st, "tx", payload)
      elseif mcmd == CMD_DEVICE_ITEM_RX then
        decode_INFO_like(st, "rx", payload)
      elseif mcmd == CMD_INFO then
        decode_INFO_like(st, "info", payload)
      elseif mcmd == CMD_PARAM_ITEM then
        on_PARAM_ITEM(st, payload)
      elseif mcmd == CMD_PARAM_ITEM2 then
        on_PARAM_ITEM2(st, payload)
      elseif mcmd == CMD_PARAM_ITEM3 then
        on_PARAM_ITEM3(st, payload)
      end
    end
  end


  -- TX write pipeline (non-blocking)
  local p = st.pendingTx
  if p then
    -- completion / retry
    if p.kind == "set" then
      if p.acked then
        st.pendingTx = nil
      elseif (now - (p.sentAt or now)) > (p.retryAfter or 0.6) then
        if (p.retries or 0) < (p.maxRetries or 2) then
          p.retries = (p.retries or 0) + 1
          p.sentAt = now
          pushMB(ctx.sensor, CMD_PARAM_SET, p.payload)
        else
          st.pendingTx = nil
          st.fetch.err = "write timeout"
          st.fetch.done = true
          st.fetch.active = false
          return
        end
      end

    elseif p.kind == "store" then
      -- Store doesn't reliably ACK; consider it done after a short settle.
      if (now - (p.sentAt or now)) > (p.settleAfter or 0.3) then
        st.pendingTx = nil
      end
    end
  end

  -- If idle and something is queued, send it.
  if (not st.pendingTx) and st.txq and #st.txq > 0 then
    local item = table.remove(st.txq, 1)
    if item and item.cmd == CMD_PARAM_SET then
      st.pendingTx = {
        kind = "set",
        idx0 = item.idx0,
        payload = item.payload,
        sentAt = now,
        acked = false,
        retries = 0,
        maxRetries = item.maxRetries or 2,
        retryAfter = item.retryAfter or 0.6,
      }
      pushMB(ctx.sensor, CMD_PARAM_SET, item.payload)
      -- When writing, keep the link awake a little (some modules are slow to init)
      st.enteredAt = st.enteredAt or now

    elseif item and item.cmd == CMD_PARAM_STORE then
      st.pendingTx = { kind = "store", sentAt = now, settleAfter = item.settleAfter or 0.3 }
      pushMB(ctx.sensor, CMD_PARAM_STORE, {})
    end
  end

  -- TX probing (suppressed while a write is in-flight)
  if not st.pendingTx and (not st.txq or #st.txq == 0) then
    if not st.haveInfo then
      if (not st.lastInfoReq) or (now - st.lastInfoReq > 1.0) then
        pushMB(ctx.sensor, CMD_REQUEST_INFO, {})
        st.lastInfoReq = now
      end
    elseif not st.paramsComplete then
      if (not st.lastParamsReq) or (now - st.lastParamsReq > 1.0) then
        pushMB(ctx.sensor, CMD_PARAM_REQUEST_LIST, {})
        st.lastParamsReq = now
      end
    end
  end
  -- done / timeout
  local elapsed = now - (st.fetch.startedAt or now)
  if st.haveInfo and st.paramsComplete then
    st.fetch.done = true
    st.fetch.active = false
    return
  end

  if elapsed > (st.fetch.timeout or 10.0) then
    st.fetch.err = "timeout"
    st.fetch.done = true
    st.fetch.active = false
    return
  end
end

-- Non-blocking “are we done yet?” + structured result
function M.poll(ctx)
  local st = ctx.st
  if not st.fetch.done then
    return false, nil, nil
  end
  if st.fetch.err then
    return true, nil, st.fetch.err
  end

  local params = {}
  for i = 1, #st.fields do
    local f = st.fields[i]
    if f and f.name and f.typ ~= nil then
      params[#params + 1] = {
        index0 = f.index0,
        name = f.name,
        typ = f.typ,
        value = f.value,
        min = f.min,
        max = f.max,
        unit = f.unit,
        options = f.options
      }
    end
  end

  local out = {
    ok = true,
    info = st.info,
    params = params,
    meta = {
      rxAny = st.rxAny,
      rxVendor130 = st.rxVendor130,
      startedAt = st.fetch.startedAt,
      finishedAt = os.clock()
    }
  }

  return true, out, nil
end

return M
