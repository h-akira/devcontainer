-- 基本設定
vim.opt.encoding = 'utf-8'
vim.opt.number = true
vim.opt.autoread = true
vim.opt.virtualedit = 'onemore'
vim.opt.showmatch = true

-- クリップボード
vim.opt.clipboard = 'unnamed,unnamedplus'

-- 検索
vim.opt.hlsearch = true
vim.opt.incsearch = true
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- インデント
vim.g.python_recommended_style = 0
vim.opt.expandtab = true
vim.opt.tabstop = 2
vim.opt.softtabstop = 2
vim.opt.shiftwidth = 2
vim.opt.smartindent = true

-- Mac向け
vim.opt.backspace = 'indent,eol,start'

-- カーソル位置記憶
local vimrcEx = vim.api.nvim_create_augroup('vimrcEx', { clear = true })
vim.api.nvim_create_autocmd('BufReadPost', {
  group = vimrcEx,
  pattern = '*',
  callback = function()
    local line = vim.fn.line("'\"")
    if line > 1 and line <= vim.fn.line('$') then
      vim.cmd('normal! g`"')
    end
  end,
})

-- プラグイン管理
require("config.lazy")

-- カラースキーム設定（プラグイン読み込み後）
vim.api.nvim_create_autocmd('VimEnter', {
  callback = function()
    -- vim.cmd('colorscheme elflord')
    -- vim.cmd('colorscheme atom-dark-256')
    vim.cmd('colorscheme atom-dark')
    -- GitHub Copilot のハイライト設定
    vim.api.nvim_set_hl(0, 'CopilotSuggestion', { fg = '#888888', italic = true })
  end,
})

-- Container-local additions (sourced last). init-nvim.sh installs an empty
-- ~/.config/nvim/add.lua on first run; user edits there persist across
-- container starts. Plugin-level additions go in
-- ~/.config/nvim/lua/plugins/add.lua (auto-imported by lazy.nvim).
local add_path = vim.fn.expand('~/.config/nvim/add.lua')
if vim.fn.filereadable(add_path) == 1 then
  dofile(add_path)
end
