
" Run:
" 1. vim -S examples/Template.vim


let s:V = vital#vital#new()
let s:Template = s:V.import('Template')
unlet s:V

function! s:run() abort
  let result = s:Template.new('Hello, {{$world}}.').render({'world': 'World'})
  call assert_equal('Hello, World.', result)
  let result = s:Template.new('Hello, {{.world}}.').render({'world': 'World'})
  call assert_equal('Hello, World.', result)
  let result = s:Template.new('{{.my.new.world}}').render({'my': {'new': {'world': 'end'}}})
  call assert_equal('end', result)

  if empty(v:errors)
    echom 'All tests were passed.'
  else
    echohl ErrorMsg
    for err in v:errors
      echom err
    endfor
    echohl None
  endif
endfunction

call s:run()
