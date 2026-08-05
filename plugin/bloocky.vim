if exists('g:loaded_bloocky') || !has('nvim-0.10')
  finish
endif
let g:loaded_bloocky = 1

command! -nargs=? Bloocky lua require('bloocky').open(<f-args>)
command! -nargs=0 BloockyToggle lua require('bloocky').toggle()
