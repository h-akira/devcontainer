" 文字コード
set encoding=utf-8

" 基本
set number
set autoread
set virtualedit=onemore
set showmatch

" クリップボード
set clipboard=unnamed,unnamedplus

"検索
set hlsearch
set incsearch
set ignorecase
set smartcase

"インデント
let g:python_recommended_style = 0
set expandtab
set tabstop=2
set softtabstop=2
set shiftwidth=2
set smartindent

" カーソル位置記憶
augroup vimrcEx
  autocmd!
  autocmd BufReadPost *
    \ if line("'\"") > 1 && line("'\"") <= line('$') |
    \   exe "normal! g`\"" |
    \ endif
augroup END

" Mac向け
set backspace=indent,eol,start

"プラグイン
call plug#begin()
Plug 'Yggdroot/indentLine'
Plug 'thinca/vim-template'
Plug 'tomtom/tcomment_vim'
Plug 'cohama/lexima.vim'
Plug 'vim-airline/vim-airline'
" カラースキーム
Plug 'jonathanfilip/vim-lucius'
Plug 'tomasr/molokai'
Plug 'gosukiwi/vim-atom-dark'
" ファイルブラウザ
Plug 'preservim/nerdtree'
Plug 'Xuyuanp/nerdtree-git-plugin'
" 補完
Plug 'Shougo/ddc.vim'
Plug 'vim-denops/denops.vim'
Plug 'Shougo/ddc-ui-native'
Plug 'Shougo/ddc-source-around'
Plug 'Shougo/ddc-matcher_head'
Plug 'Shougo/ddc-sorter_rank'
Plug 'LumaKernel/ddc-file'
Plug 'mattn/vim-lsp-settings'
Plug 'prabirshrestha/vim-lsp'
Plug 'shun/ddc-source-vim-lsp'
Plug 'github/copilot.vim'
" 追加
if has('nvim')
  if filereadable(expand('~/.config/nvim/add.plugin.vimrc'))
    source ~/.config/nvim/add.plugin.vimrc
  endif
else
  if filereadable(expand('~/.vim/add.plugin.vimrc'))
    source ~/.vim/add.plugin.vimrc
  endif
endif
call plug#end()

" コメントアウト
let g:tcomment_opleader1 = 'fc'
setlocal formatoptions-=ro

" カラースキーム
" colorscheme lucius
" colorscheme molokai
colorscheme atom-dark-256

"カーソル
" set cursorline
" set cursorcolumn
" highlight CursorLine cterm=underline ctermfg=NONE ctermbg=NONE
" highlight CursorLine gui=underline guifg=NONE guibg=NONE

" ファイルブラウザ
nnoremap <leader>n :NERDTreeFocus<CR>
nnoremap <C-n> :NERDTree<CR>
nnoremap <C-t> :NERDTreeToggle<CR>
nnoremap <C-f> :NERDTreeFind<CR>

" テンプレート
autocmd User plugin-template-loaded call s:template_keywords()
function! s:template_keywords()
	%s/<+DATE+>/\=strftime('%Y-%m-%d %H:%M:%S')/g
endfunction
autocmd User plugin-template-loaded
\    if search('<+CURSOR+>')
\  |   execute 'normal! "_da>'
\  | endif

""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" 補完
let g:lsp_diagnostics_signs_enabled = 0
let g:lsp_diagnostics_highlights_enabled = 0
let g:lsp_diagnostics_enabled = 0
let g:lsp_document_code_action_signs_enabled = 0
let g:lsp_document_highlight_delay = 0
let g:lsp_log_file = ""
let g:lsp_auto_enable = 0

call ddc#custom#patch_global('ui', 'native')
call ddc#custom#patch_global('sourceParams', #{
      \   around: #{ maxSize: 500 },
      \ })
call ddc#custom#patch_global('sources', ['file', 'around', 'vim-lsp'])
call ddc#custom#patch_global('sourceOptions', {
      \ '_': {
      \   'matchers': ['matcher_head'],
      \   'sorters': ['sorter_rank']
      \},
      \ 'file': {
      \   'mark': 'F',
      \   'isVolatile': v:true,
      \   'forceCompletionPattern': '\S/\S*',
      \ },
      \ 'vim-lsp': {
      \   'mark': 'lsp', 
      \   'matchers': ['matcher_head'],
      \ }
      \})
call ddc#custom#patch_filetype(
    \ ['ps1', 'dosbatch', 'autohotkey', 'registry'], {
      \ 'sourceOptions': {
      \   'file': {
      \     'forceCompletionPattern': '\S\\\S*',
    \   },
    \ },
    \ 'sourceParams': {
      \   'file': {
      \     'mode': 'win32',
    \   },
    \ }})

" <TAB>: completion.
inoremap <silent><expr> <TAB>
\ pumvisible() ? '<C-n>' :
\ (col('.') <= 1 <Bar><Bar> getline('.')[col('.') - 2] =~# '\s') ?
\ '<TAB>' : ddc#map#manual_complete()

" <S-TAB>: completion back.
inoremap <expr><S-TAB>  pumvisible() ? '<C-p>' : '<C-h>'

" Use ddc.
call ddc#enable()

" 参考
" https://github.com/Shougo/ddc.vim
" https://github.com/LumaKernel/ddc-source-file
""""""""""""""""""""""""""""""""""""""""""""""""""""""""

" 追加
if has('nvim')
  if filereadable(expand('~/.config/nvim/add.vimrc'))
    source ~/.config/nvim/add.vimrc
  endif
else
  if filereadable(expand('~/.vim/add.vimrc'))
    source ~/.vim/add.vimrc
  endif
endif
