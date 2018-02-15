let s:save_cpo = &cpo
set cpo&vim

" Ref:
" Lexical Scanning in Go
" https://www.youtube.com/watch?v=HxaD_trXwRE


function! s:new(expr) abort
  let t = {}
  let t.render = funcref('s:_Template_render')
  let t._r = s:_compile(a:expr)
  return t
endfunction

function! s:_Template_render(param) abort dict
  return self._r(a:param)
endfunction

function! s:_compile(expr) abort
  let tokens = s:_lex(a:expr)
  if !empty(tokens) && tokens[-1].type is# s:TOKEN_ERROR
    throw 'Template: tokenizing error: ' . tokens[-1].msg
  endif
  " PP! tokens
  let ast = s:_parse(tokens)
  " PP! ast
  function! s:_render(param) abort closure
    let ctx = {'root': a:param, 'current': a:param}
    return join(map(ast, {_,node -> node.to_string(ctx)}), '')
  endfunction
  return funcref('s:_render')
endfunction

let s:NODE_TEXT = 0
let s:NODE_EXPR = 1

function! s:_parse(tokens) abort
  let tokens = a:tokens
  let ast = []
  while !empty(tokens) && tokens[0].type isnot# s:TOKEN_EOF
    let t = remove(tokens, 0)
    if t.type is# s:TOKEN_TEXT
      let node = {str -> {'type': s:NODE_TEXT, 'to_string': {-> str}}}(t.str)
      let ast += [node]
    elseif t.type is# s:TOKEN_LEFT_META
      call s:_parse_inside_action(ast, tokens)
    else
      throw 'Template: Not implemented yet'
    endif
  endwhile
  return ast
endfunction

function! s:_parse_inside_action(ast, tokens) abort
  let ast = a:ast
  let tokens = a:tokens
  if empty(tokens)
    throw 'Template: parse error: no tokens inside ' . s:LEFT_META
  endif
  let t0 = remove(tokens, 0)
  if t0.type is# s:TOKEN_STRING
    call s:_next_token(tokens, s:TOKEN_RIGHT_META, s:RIGHT_META)
    let str = eval(t0.str[1:-2])
    let node = {'type': s:NODE_EXPR, 'to_string': {-> str}}
    let ast += [node]
  elseif t0.type is# s:TOKEN_RAW_STRING
    call s:_next_token(tokens, s:TOKEN_RIGHT_META, s:RIGHT_META)
    let str = t0.str[1:-2]
    let node = {'type': s:NODE_EXPR, 'to_string': {-> str}}
    let ast += [node]
  elseif t0.type is# s:TOKEN_NUMBER
    " TODO: More complex number format (see s:_lex_number())
    call s:_next_token(tokens, s:TOKEN_RIGHT_META, s:RIGHT_META)
    let str = (+t0.str) . ""
    let node = {'type': s:NODE_EXPR, 'to_string': {-> str}}
    let ast += [node]
  elseif t0.type is# s:TOKEN_IDENTIFIER
    if t0.str[0] is# '$'
      call s:_next_token(tokens, s:TOKEN_RIGHT_META, s:RIGHT_META)
      let name = t0.str[1:]
      let node = {'type': s:NODE_EXPR, 'to_string': {ctx -> get(ctx.root, name, '')}}
      let ast += [node]
    elseif t0.str[0] is# '.'
      call s:_next_token(tokens, s:TOKEN_RIGHT_META, s:RIGHT_META)
      if t0.str !~# '^\.\|\(\.[[:alnum:]]\+\)\+$'
        throw 'Template: parse error: invalid varname: ' . t0.str
      endif
      function! s:_stringer(ctx) closure
        let Value = a:ctx.current
        for prop in split(t0.str, '\.')
          let Value = Value[prop]
        endfor
        return Value
      endfunction
      let node = {'type': s:NODE_EXPR, 'to_string': funcref('s:_stringer')}
      let ast += [node]
    else
      throw 'Template: Not implemented yet'
    endif
  else
    throw 'Template: Not implemented yet'
  endif
endfunction

function! s:_next_token(tokens, type, str) abort
  if empty(a:tokens)
    throw printf('Template: parse error: expected ''%s'' but got no more tokens',
    \             a:str)
  endif
  let t = remove(a:tokens, 0)
  if t.type isnot# a:type
    throw printf('Template: parse error: expected ''%s'' but got ''%s''',
    \             a:str, t.str)
  endif
  return t
endfunction

function! s:_lex(expr) abort
  let lexer = s:_new_lexer(a:expr)
  let l:Lex = funcref('s:_lex_text')
  while l:Lex isnot# v:null
    let l:Lex = l:Lex(lexer)
  endwhile
  return lexer.tokens
endfunction

let s:TOKEN_TEXT = 0
let s:TOKEN_LEFT_META = 1
let s:TOKEN_RIGHT_META = 2
let s:TOKEN_PIPE = 3
let s:TOKEN_NUMBER = 4
let s:TOKEN_STRING = 5
let s:TOKEN_RAW_STRING = 6
let s:TOKEN_IDENTIFIER = 7
let s:TOKEN_EOF = 99
let s:TOKEN_ERROR = 999

function! s:_new_lexer(input) abort
  let lexer = {
  \ 'input': a:input,
  \ 'start': 0,
  \ 'pos': 0,
  \ 'eof_pos': strlen(a:input),
  \ 'width': 0,
  \ 'tokens': [],
  \}

  function! lexer.emit(type) abort
    let token = {'type': a:type, 'str': self.input[self.start : self.pos - 1]}
    let self.tokens += [token]
    let self.start = self.pos
  endfunction

  function! lexer.errorf(fmt, ...) abort
    let msg = a:0 ? call('printf', [a:fmt] + a:000) : a:fmt
    let token = {'type': s:TOKEN_ERROR, 'msg': msg}
    let self.tokens += [token]
    return v:null
  endfunction

  function! lexer.next() abort
    if self.pos >=# self.eof_pos
      let self.width = 0
      return s:EOF
    endif
    let c = matchstr(self.input, '.', self.pos)
    let self.width = strlen(c)
    let self.pos += self.width
    return c
  endfunction

  function! lexer.peek() abort
    let c = self.next()
    call self.backup()
    return c
  endfunction

  function! lexer.ignore() abort
    let self.start = self.pos
  endfunction

  function! lexer.backup() abort
    let self.pos -= self.width
  endfunction

  function! lexer.accept(charset) abort
    if index(a:charset, self.next(), self.pos) >=# 0
      return v:true
    endif
    call self.backup()
    return v:false
  endfunction

  function! lexer.accept_run(charset) abort
    while match(a:charset, self.next(), self.pos) >=# 0
    endif
    call self.backup()
  endfunction

  function! lexer.starts_with(str) abort
    return self.input[self.pos : self.pos + strlen(a:str) - 1] is# a:str
  endfunction

  return lexer
endfunction

let s:LEFT_META = '{{'
let s:RIGHT_META = '}}'

let s:EOF = -1

function! s:_lex_text(l) abort
  while 1
    if a:l.starts_with(s:LEFT_META)
      if a:l.pos > a:l.start
        call a:l.emit(s:TOKEN_TEXT)
      endif
      return funcref('s:_lex_left_meta')
    endif
    if a:l.next() is# s:EOF
      break
    endif
  endwhile
  if a:l.pos > a:l.start
    call a:l.emit(s:TOKEN_TEXT)
  endif
  call a:l.emit(s:TOKEN_EOF)
  return v:null
endfunction

" When this function is called, a:l.input[a:l.pos :] starts with s:LEFT_META
function! s:_lex_left_meta(l) abort
  let a:l.pos += strlen(s:LEFT_META)
  call a:l.emit(s:TOKEN_LEFT_META)
  return funcref('s:_lex_inside_action')
endfunction

" When this function is called, a:l.input[a:l.pos :] starts with s:RIGHT_META
function! s:_lex_right_meta(l) abort
  let a:l.pos += strlen(s:RIGHT_META)
  call a:l.emit(s:TOKEN_RIGHT_META)
  return funcref('s:_lex_text')
endfunction

" When this function is called, a:l.pos is inside s:LEFT_META and s:RIGHT_META
function! s:_lex_inside_action(l) abort
  while 1
    if a:l.starts_with(s:RIGHT_META)
      return funcref('s:_lex_right_meta')
    endif
    let c = a:l.next()
    if c is# s:EOF || c is# "\n"
      return a:l.errorf('unclosed action')
    elseif c =~# '[[:space:]]'
      call a:l.ignore()
    elseif c is# '|'
      call a:l.emit(s:TOKEN_PIPE)
    elseif c is# '"'
      return funcref('s:_lex_quote')
    elseif c is# '`'
      return funcref('s:_lex_raw_quote')
    elseif c =~# '[-+0-9]'
      call a:l.backup()
      return funcref('s:_lex_number')
    elseif c =~# '[[:alnum:]]'
      call a:l.backup()
      return funcref('s:_lex_identifier')
    endif
  endwhile
endfunction

function! s:_lex_quote(l) abort
  let a:l.pos += strlen('"')
  let prev = ''
  while 1
    let c = a:l.next()
    if c is# s:EOF
      return a:l.errorf('unclosed quote')
    elseif c is# '"' && prev isnot# '\'
      break
    endif
    let prev = c
  endwhile
  call a:l.emit(s:TOKEN_STRING)
  return funcref('s:_lex_inside_action')
endfunction

function! s:_lex_raw_quote(l) abort
  let a:l.pos += strlen('`')
  let prev = ''
  while 1
    let c = a:l.next()
    if c is# s:EOF
      return a:l.errorf('unclosed quote')
    elseif c is# '`'
      break
    endif
    let prev = c
  endwhile
  call a:l.emit(s:TOKEN_RAW_STRING)
  return funcref('s:_lex_inside_action')
endfunction

function! s:_lex_number(l) abort
  call a:l.accept('+-')
  let digits = '0123456789'
  if a:l.accept('0') || a:l.accept('xX')
    let digits = '0123456789abcdefABCDEF'
  endif
  call a:l.accept_run(digits)
  if a:l.accept('.')
    call a:l.accept_run(digits)
  endif
  if a:l.accept('eE')
    call a:l.accept('+-')
    call a:l.accept_run('0123456789')
  endif
  call a:l.accept('i')
  if a:l.peek() =~# '[[:alnum:]]'
    call a:l.next()
    return a:l.errorf('bad number syntax: %s', a:l.input[a:l.start : a:l.pos])
  endif
  call a:l.emit(s:TOKEN_NUMBER)
  return funcref('s:_lex_inside_action')
endfunction

function! s:_lex_identifier(l) abort
  while 1
    let c = a:l.next()
    if c is# s:EOF || c !~# '[.$:=[:alnum:]]'
      break
    endif
  endwhile
  call a:l.backup()
  call a:l.emit(s:TOKEN_IDENTIFIER)
  return funcref('s:_lex_inside_action')
endfunction


function! s:_skip_spaces(str) abort
  return substitute(a:str, '^\s\+', '', '')
endfunction


let &cpo = s:save_cpo
unlet s:save_cpo

" vim:set et ts=2 sts=2 sw=2 tw=0:
