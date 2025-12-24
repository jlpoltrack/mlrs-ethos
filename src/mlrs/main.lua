-- main.lua
-- Ethos entrypoints + wiring around mlrs.lua

local mlrs = assert(loadfile("mlrs.lua"))()

local function debugDumpTable(t, indent, seen)
  indent = indent or ""
  seen = seen or {}

  if type(t) ~= "table" then
    print(indent .. tostring(t))
    return
  end

  if seen[t] then
    print(indent .. "*cycle*")
    return
  end
  seen[t] = true

  for k, v in pairs(t) do
    if type(v) == "table" then
      print(indent .. tostring(k) .. " = {")
      debugDumpTable(v, indent .. "  ", seen)
      print(indent .. "}")
    else
      print(indent .. tostring(k) .. " = " .. tostring(v))
    end
  end
end

local function create()
  local ctx = mlrs.createContext()

  -- last completed read
  ctx.data = nil
  ctx.err  = nil

  -- “start once” guard per open
  ctx._started = false

  -- write lifecycle helpers (UI layer can use these)
  ctx._writeWasBusy = false     -- tracks rising/falling edge of write queue busy
  ctx._refetchAfterWrite = true -- set false if you don't want auto-refresh
  ctx._refetchQueued = false

  return ctx
end

local function wakeup(widget)
  -- Start initial fetch once per open
  if not widget._started then
    widget._started = true
    mlrs.request(widget, { timeout = 12.0, settle = 1.5 })
  end

  -- Always pump protocol engine (drives BOTH reads and writes)
  mlrs.process(widget)

  -- Capture read result once (but don't stop pumping after)
  if not widget.data and not widget.err then
    local done, data, err = mlrs.poll(widget)
    if done then
      widget.data = data
      widget.err  = err

      -- DEBUG: print returned structure once
      if data and not widget._debugDumped then
        widget._debugDumped = true
        print("===== MLRS DATA BEGIN =====")
        debugDumpTable(data)
        print("===== MLRS DATA END =====")
      end

      if err then
        print("MLRS ERROR:", err)
      end
    end
  end

  -- Optional: auto-refetch after a write batch completes
  -- (useful so your UI sees updated values without manual refresh)
  if mlrs.isWriteBusy then
    local busy = mlrs.isWriteBusy(widget)

    -- detect "busy -> not busy" transition
    if widget._writeWasBusy and not busy then
      if widget._refetchAfterWrite then
        widget._refetchQueued = true
      end
    end

    widget._writeWasBusy = busy
  end

  -- If a refetch was queued (e.g. after writes), start it once.
  if widget._refetchQueued then
    widget._refetchQueued = false
    widget.data = nil
    widget.err = nil
    widget._started = true -- already started, just re-request
    mlrs.request(widget, { timeout = 12.0, settle = 0.2 })
  end
end

local function close(widget)
  if widget and widget.st then
    widget.st.fetch.active = false
  end
  if collectgarbage then collectgarbage() end
end

local function event(widget, category, value, x, y)
  return false
end

local function init()
  local version = system.getVersion()
  local major, minor = version.major, version.minor

  if major >= 1 and minor >= 7 then
    system.registerMlrsModule({
      configure = {
        name = "MLRS",
        create = create,
        wakeup = wakeup,
        event = event,
        close = close
      }
    })
  else
    system.registerSystemTool({
      name = "MLRS",
      create = create,
      wakeup = wakeup,
      event = event,
      close = close
    })
  end
end

return { init = init }
