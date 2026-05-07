return {
  -- UI Enhancement
  "Yggdroot/indentLine",
  "vim-airline/vim-airline",

  -- カラースキーム
  -- "jonathanfilip/vim-lucius",
  -- "tomasr/molokai",
  "gosukiwi/vim-atom-dark",

  -- ファイルブラウザ
  {
    "preservim/nerdtree",
    dependencies = { "Xuyuanp/nerdtree-git-plugin" },
    keys = {
      { "<leader>n", "<cmd>NERDTreeFocus<CR>", desc = "NERDTree Focus" },
      { "<C-n>", "<cmd>NERDTree<CR>", desc = "NERDTree Open" },
      { "<C-t>", "<cmd>NERDTreeToggle<CR>", desc = "NERDTree Toggle" },
      { "<C-f>", "<cmd>NERDTreeFind<CR>", desc = "NERDTree Find" },
    },
  },

  -- コメントアウト
  {
    "tomtom/tcomment_vim",
    keys = {
      { "fc", mode = { "n", "v" }, desc = "TComment operator" },
    },
    init = function()
      vim.g.tcomment_opleader1 = "fc"
    end,
  },
  -- 括弧を閉じる
  "cohama/lexima.vim",

  -- テンプレート
  {
    "thinca/vim-template",
    config = function()
      local template_group = vim.api.nvim_create_augroup('TemplateConfig', { clear = true })
      vim.api.nvim_create_autocmd('User', {
        group = template_group,
        pattern = 'plugin-template-loaded',
        callback = function()
          vim.cmd([[%s/<+DATE+>/\=strftime('%Y-%m-%d %H:%M:%S')/g]])
        end,
      })
      vim.api.nvim_create_autocmd('User', {
        group = template_group,
        pattern = 'plugin-template-loaded',
        callback = function()
          if vim.fn.search('<+CURSOR+>') > 0 then
            vim.cmd('normal! "_da>')
          end
        end,
      })
    end,
  },

  -- LSP と補完
  {
    "prabirshrestha/vim-lsp",
    dependencies = { "mattn/vim-lsp-settings" },
    config = function()
      vim.g.lsp_diagnostics_signs_enabled = 0
      vim.g.lsp_diagnostics_highlights_enabled = 0
      vim.g.lsp_diagnostics_enabled = 0
      vim.g.lsp_document_code_action_signs_enabled = 0
      vim.g.lsp_document_highlight_delay = 0
      vim.g.lsp_log_file = ""
    end,
  },

  -- ddc.vim 補完システム
  {
    "Shougo/ddc.vim",
    dependencies = {
      "vim-denops/denops.vim",
      "Shougo/ddc-ui-native",
      "Shougo/ddc-source-around",
      "Shougo/ddc-matcher_head",
      "Shougo/ddc-sorter_rank",
      "LumaKernel/ddc-file",
      "shun/ddc-source-vim-lsp",
    },
    config = function()
      vim.fn['ddc#custom#patch_global']('ui', 'native')
      vim.fn['ddc#custom#patch_global']('sourceParams', {
        around = { maxSize = 500 },
      })
      vim.fn['ddc#custom#patch_global']('sources', {'file', 'around', 'vim-lsp'})
      vim.fn['ddc#custom#patch_global']('sourceOptions', {
        ['_'] = {
          matchers = {'matcher_head'},
          sorters = {'sorter_rank'}
        },
        file = {
          mark = 'F',
          isVolatile = true,
          forceCompletionPattern = '\\S/\\S*',
        },
        ['vim-lsp'] = {
          mark = 'lsp',
          matchers = {'matcher_head'},
        }
      })
      vim.fn['ddc#custom#patch_filetype'](
        {'ps1', 'dosbatch', 'autohotkey', 'registry'}, {
          sourceOptions = {
            file = {
              forceCompletionPattern = '\\S\\\\\\S*',
            },
          },
          sourceParams = {
            file = {
              mode = 'win32',
            },
          }
        })
      
      -- キーマッピング
      vim.keymap.set('i', '<Tab>', function()
        if vim.fn.pumvisible() == 1 then
          return '<C-n>'
        elseif vim.fn.col('.') <= 1 or vim.fn.getline('.'):sub(vim.fn.col('.') - 1, vim.fn.col('.') - 1):match('%s') then
          return '<Tab>'
        else
          return vim.fn['ddc#map#manual_complete']()
        end
      end, { expr = true, silent = true })
      
      vim.keymap.set('i', '<S-Tab>', function()
        if vim.fn.pumvisible() == 1 then
          return '<C-p>'
        else
          return '<C-h>'
        end
      end, { expr = true })

      vim.fn['ddc#enable']()
    end,
  },

  -- GitHub Copilot
  "github/copilot.vim",

  -- snacks.nvim (明示的に追加)
  "folke/snacks.nvim",

  -- Claude Code
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    lazy = false,
    opts = {
      diff_opts = {
        vertical_split = false,  -- 横分割に変更
        auto_close_on_accept = true,
        open_in_current_tab = true,
        keep_terminal_focus = false,
      },
    },
    config = true,
  },
  -- {
  --   "greggh/claude-code.nvim",
  --   dependencies = {
  --     "nvim-lua/plenary.nvim", -- Required for git operations
  --   },
  --   config = function()
  --     require("claude-code").setup()
  --   end
  -- },
}
