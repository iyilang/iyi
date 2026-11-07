if exists('b:did_ftplugin')
  finish
endif
let b:did_ftplugin = 1
setlocal commentstring=#\ %s comments=:#
setlocal expandtab shiftwidth=2 softtabstop=2
let b:undo_ftplugin = 'setlocal commentstring< comments< expandtab< shiftwidth< softtabstop<'
