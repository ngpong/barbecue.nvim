local M = {}

local async = require("plenary.async")

local uv = vim.loop

local function tbl_pack(...)
  return { n = select("#", ...), ... }
end

local function tbl_unpack(t, i, j)
  return table.unpack(t, i or 1, j or t.n or table.maxn(t))
end

function M.try_close(...)
  local args = { ... }

  for i = 1, select("#", ...) do
    local handle = args[i]

    if handle and not handle:is_closing() then
      handle:close()
    end
  end
end

local function wrap(timer, fn)
  return setmetatable({}, {
    __call = function(_, ...)
      fn(...)
    end,
    __index = {
      close = function()
        timer:stop()
        M.try_close(timer)
      end,
    },
  })
end

function M.debounce_leading(ms, fn)
  local timer = assert(uv.new_timer())
  local lock = false

  return wrap(timer, function(...)
    timer:start(ms, 0, function()
      timer:stop()
      lock = false
    end)

    if not lock then
      lock = true
      fn(...)
    end
  end)
end

function M.debounce_trailing(ms, rush_first, fn)
  local timer = assert(uv.new_timer())
  local lock = false
  local debounced_fn, args

  debounced_fn = wrap(timer, function(...)
    if not lock and rush_first and args == nil then
      lock = true
      fn(...)
    else
      args = tbl_pack(...)
    end

    timer:start(ms, 0, function()
      lock = false
      timer:stop()
      if args then
        local a = args
        args = nil
        fn(tbl_unpack(a))
      end
    end)
  end)

  return debounced_fn
end

function M.throttle_leading(ms, fn)
  local timer = assert(uv.new_timer())
  local lock = false

  return wrap(timer, function(...)
    if not lock then
      timer:start(ms, 0, function()
        lock = false
        timer:stop()
      end)

      lock = true
      fn(...)
    end
  end)
end

function M.throttle_trailing(ms, rush_first, fn)
  local timer = assert(uv.new_timer())
  local lock = false
  local throttled_fn, args

  throttled_fn = wrap(timer, function(...)
    if lock or (not rush_first and args == nil) then
      args = tbl_pack(...)
    end

    if lock then return end

    lock = true

    if rush_first then
      fn(...)
    end

    timer:start(ms, 0, function()
      lock = false
      if args then
        local a = args
        args = nil
        if rush_first then
          throttled_fn(tbl_unpack(a))
        else
          fn(tbl_unpack(a))
        end
      end
    end)
  end)

  return function(...)
    throttled_fn(...)
  end
end

function M.throttle_render(framerate, fn)
  local lock = false
  local use_framerate = framerate > 0
  local period = use_framerate and (1000 / framerate) * 1E6 or 0
  local throttled_fn
  local args, last

  throttled_fn = async.void(function(...)
    args = tbl_pack(...)
    if lock then return end

    lock = true
    async.util.scheduler()
    fn(tbl_unpack(args))
    args = nil

    if use_framerate then
      local now = uv.hrtime()

      if last and now - last < period then
        local wait = period - (now - last)
        async.util.sleep(wait / 1E6)
        last = last + period
      else
        last = now
      end
    end

    lock = false

    if args ~= nil then
      throttled_fn(tbl_unpack(args))
    end
  end)

  return throttled_fn
end

function M.set_interval(func, delay)
  local timer = assert(uv.new_timer())

  local ret = {
    close = function()
      timer:stop()
      M.try_close(timer)
    end,
  }

  timer:start(delay, delay, function()
    local should_close = func()
    if type(should_close) == "boolean" and should_close then
      ret.close()
    end
  end)

  return ret
end

function M.set_timeout(func, delay)
  local timer = assert(uv.new_timer())

  local ret = {
    close = function()
      timer:stop()
      M.try_close(timer)
    end,
  }

  timer:start(delay, 0, function()
    func()
    ret.close()
  end)

  return ret
end

return M

