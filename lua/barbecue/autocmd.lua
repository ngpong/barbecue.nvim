local navic = require("nvim-navic")
local config = require("barbecue.config")
local ui = require("barbecue.ui")
local utils = require("barbecue.utils")
local theme = require("barbecue.theme")
local bouncer = require("barbecue.debounce")

local async = require("plenary.async")

local navic_lib = require("nvim-navic.lib")

local M = {}

---Attach navic to capable LSPs on their initialization.
function M.create_navic_attacher()
  local group = vim.api.nvim_create_augroup("barbecue.attacher", {})
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client then
        return
      end

      if not client.server_capabilities["documentSymbolProvider"] then
        vim.b[args.buf].barbecu_enable = false
        return
      end

      if config.user.attach_filter and not config.user.attach_filter(args) then
        vim.b[args.buf].barbecu_enable = false
        return
      end

      navic.attach(client, args.buf)

      vim.b[args.buf].barbecu_enable = true
    end,
  })
  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    callback = function(args)
      vim.b[args.buf].barbecu_enable = false
    end,
  })

  -- nvim-navic获取符号的时机是 { "InsertLeave", "BufEnter", "CursorHold", "AttachNavic" }，可能会有一些临界的情况漏掉，故这里是进行一个补充
  local __executing = false
  local __async_f = function()
    local mode = vim.api.nvim_get_mode()
    if mode.mode == "i" or mode.blocking then
      return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if not vim.b[bufnr].barbecu_enable then
      return
    end

    local clis = vim.lsp.get_clients({ bufnr = bufnr })
    if not next(clis) then
      return
    end

    -- 防止一些慢速LS存在消息积压的情况
    if __executing then
      return
    else
      __executing = true
    end

    navic_lib.request_symbol(bufnr, vim.schedule_wrap(function(_bufnr, _symbols)
      if not vim.api.nvim_buf_is_valid(_bufnr) then
        return
      end

      navic_lib.update_data(_bufnr, _symbols)

      __executing = false
    end), clis[1])
  end
  async.run(function()
    while true do
      __async_f()
      async.util.sleep(1500)
    end
  end)
end

---Update winbar on necessary events.
function M.create_updater()
  local group = vim.api.nvim_create_augroup("barbecue.updater", { clear = true })

  -- 0x1: 保证任何文件都有最基础的 wintab 显示；该 wintab 主要负责显示文件名
  local b1 = bouncer.throttle_leading(10, vim.schedule_wrap(function(args)
    local bufnr = args.buf
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local winid = vim.fn.bufwinid(bufnr)
    if not vim.api.nvim_win_is_valid(winid) then
      return
    end

    ui.update(winid, bufnr)
  end))
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinResized", }, {
    group = group,
    callback = function(...)
      b1(...)
    end
  })

  -- 0x2: 保证仅附加了navic的文件能够更新tabline的状态(因为只有它们会存在符号)
  local __proc_insert_leave = false
  local b2 = bouncer.throttle_trailing(350, true, vim.schedule_wrap(function(args)
    local bufnr = args.buf
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    if not vim.b[bufnr].barbecu_enable then
      return
    end

    local winid = vim.fn.bufwinid(bufnr)
    if not vim.api.nvim_win_is_valid(winid) then
      return
    end

    if args.event == "CursorMoved" and __proc_insert_leave then
      __proc_insert_leave = false
      return
    end

    if args.event == "InsertLeave" then
      __proc_insert_leave = true
    end

    navic_lib.update_context(bufnr)
    ui.update(winid, bufnr)
  end))
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertLeave", }, {
    group = group,
    callback = function(args)
      b2(args)
    end
  })
end

---Keep the theme in sync with the current colorscheme.
function M.create_colorscheme_synchronizer()
  vim.api.nvim_create_autocmd("ColorScheme", {
    desc = "Colorscheme Synchronizer",
    group = vim.api.nvim_create_augroup("barbecue.colorscheme_synchronizer", {}),
    callback = function() theme.load() end,
  })
end

return M
