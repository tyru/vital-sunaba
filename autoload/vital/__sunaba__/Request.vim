let s:save_cpo = &cpo
set cpo&vim


function! s:_vital_depends() abort
  return ['Async.Promise', 'Web.URI']
endfunction

function! s:_vital_loaded(V) abort
  let s:P = a:V.import('Async.Promise')
  let s:URI = a:V.import('Web.URI')

  let s:CRLF = "\r\n"
endfunction


function! s:_defer() abort
  let d = {}
  let d.promise = s:P.new({resolve, reject -> extend(d, {
  \ 'resolve': resolve, 'reject': reject,
  \})})
  return d
endfunction


function! s:head(uri, ...) abort dict
  let options = a:0 && type(a:1) is# v:t_dict ? a:1 : {}
  return s:request('HEAD', a:uri, options)
endfunction

function! s:get(uri, ...) abort dict
  let options = a:0 && type(a:1) is# v:t_dict ? a:1 : {}
  return s:request('GET', a:uri, options)
endfunction

function! s:delete(uri, ...) abort dict
  let options = a:0 && type(a:1) is# v:t_dict ? a:1 : {}
  return s:request('DELETE', a:uri, options)
endfunction

function! s:put(uri, ...) abort dict
  let options = a:0 && type(a:1) is# v:t_dict ? a:1 : {}
  return s:request('PUT', a:uri, options)
endfunction

function! s:post(uri, ...) abort dict
  let options = a:0 && type(a:1) is# v:t_dict ? a:1 : {}
  return s:request('POST', a:uri, options)
endfunction

function! s:patch(uri, ...) abort dict
  let options = a:0 && type(a:1) is# v:t_dict ? a:1 : {}
  return s:request('PATCH', a:uri, options)
endfunction

" NOTE: Vim channel cannot send to non-plain protocol like "https://".
" Caller must detect if uri is non-plain protocol or not.
function! s:request(method, uri, ...) abort
  let options = a:0 && type(a:1) is# v:t_dict ? a:1 : {}
  return s:P.new({resolve, reject ->
  \ s:_dial(resolve, reject, a:method, a:uri, options)
  \})
endfunction

function! s:_dial(resolve, reject, method, uri, options) abort
  let [method, uri, options] = [a:method, a:uri, a:options]
  if type(method) isnot# v:t_string
    throw 'Request: method is not String'
  endif
  if type(uri) is# v:t_string
    let uri = s:URI.new(uri)
  endif
  if type(uri) isnot# v:t_dict || type(uri.scheme) isnot# v:t_func
    throw 'Request: uri is not URI object'
  endif
  if type(a:options) isnot# v:t_dict
    throw 'Request: method is not Dictionary'
  endif

  let self = {}
  let self._chunk = s:P.resolve('')
  let self._read_requests = []
  let self._res = {}
  let self._resolve = a:resolve
  let self._reject = a:reject
  let self._options = a:options

  let deferred = s:_defer()
  return s:_send(self, deferred.promise, method, uri, a:options)
          \.then(deferred.resolve)
          \.catch({-> call(a:reject, a:000)})
endfunction

function! s:_send(self, after_send, method, uri, options) abort
  let self = a:self

  let addr = a:uri.host() . ':' . a:uri.port()
  let self._channel = ch_open(addr, {
  \ 'mode': 'raw',
  \ 'drop': 'never',
  \ 'callback': {_, msg -> a:after_send.then({-> s:_on_msg(self, msg)})},
  \})
  try
    call ch_sendraw(self._channel, s:_make_request_content(a:method, a:uri, a:options))
  catch /E906:/
    " E906: not an open channel
    return s:P.reject({
    \ 'exception': printf('failed to open ''%s'': %s', addr, v:exception),
    \ 'throwpoint': v:throwpoint,
    \})
  endtry

  let interval = get(a:options, 'timer_interval', 200)
  let self._timer = timer_start(interval, {-> ch_status(self._channel)}, {'repeat': -1})

  return s:P.resolve()
endfunction

function! s:_make_request_content(method, uri, options) abort
  let lines = [
  \ a:method . ' ' . a:uri.path() . ' HTTP/1.1',
  \ 'Host: ' . a:uri.host() . ':' . a:uri.port()
  \]
  if has_key(a:options, 'headers')
    let lines += map(
    \ items(get(a:options, 'headers', {})),
    \ {_, kv -> kv[0] . ': ' . kv[1]}
    \)
  endif
  let lines += ['']
  let lines += [get(a:options, 'data', '')]
  return join(lines, s:CRLF)
endfunction

function! s:_on_msg(self, msg) abort
  let self = a:self
  let self._chunk = self._chunk.then({chunk -> chunk . a:msg})
  call s:_parse(self).catch({err -> s:_reject(self, err)})
  " Notify to readers
  while !empty(self._read_requests)
    let resolve = remove(self._read_requests, -1)
    call resolve()
  endwhile
endfunction

function! s:_parse(self) abort
  let self = a:self
  return s:_parse_status_line(self)
endfunction

function! s:_parse_status_line(self) abort
  let self = a:self
  return s:_read_until(self, s:CRLF).then({
  \ line -> s:_do_parse_status_line(self, line)
  \})
endfunction

function! s:_do_parse_status_line(self, line) abort
  let self = a:self
  let STATUS_LINE = '^HTTP/\([0-9]\+\.[0-9]\+\)[[:blank:]]\+\([0-9]\{3}\)[[:blank:]]\+\([^\r\n]*\)$'
  let m = matchlist(a:line, STATUS_LINE)
  if empty(m)
    return s:P.reject('failed to parse status line')
  endif
  let self._res.http_version = m[1]
  let self._res.status_code = m[2]
  let self._res.status_text = m[3]
  return s:_parse_headers(self)
endfunction

function! s:_parse_headers(self) abort
  let self = a:self
  if !has_key(self._res, 'headers')
    let self._res.headers = {}
  endif
  return s:_read_until(self, s:CRLF).then({
  \ line -> s:_do_parse_header(self, line)
  \})
endfunction

function! s:_do_parse_header(self, line) abort
  let self = a:self
  if a:line ==# ''    " the line only CRLF
    return s:_parse_content(self)
  endif
  " TODO:
  " * Stricter pattern
  " * Header field can wrap over multiple lines (LWS)
  let HEADER_LINE = '^\(\S\+\):[[:space:]]*\(.*\)$'
  let m = matchlist(a:line, HEADER_LINE)
  if empty(m)
    return s:P.reject('failed to parse header: ' . string(line))
  endif
  let [key, value] = m[1:2]
  let self._res.headers[tolower(key)] = value
  " next header
  return s:_parse_headers(self)
endfunction

function! s:_parse_content(self) abort
  let self = a:self
  let length = get(self._res.headers, 'content-length', v:null)
  if length is# v:null
    " TODO: chunked encoding
    " Parsing was end
    call s:_resolve(self, s:_make_response(self, self._options))
    return s:P.resolve()
  endif
  return s:_read(self, str2nr(length)).then({
  \ content -> s:_do_parse_content(self, content)
  \})
endfunction

function! s:_do_parse_content(self, content) abort
  let self = a:self
  let self._res.content = a:content
  " Parsing was end
  call s:_resolve(self, s:_make_response(self, self._options))
endfunction

function! s:_read(self, n) abort
  let self = a:self
  if a:n <=# 0
    return s:P.reject('Request: s:_read(): invalid argument was given: ' . a:n)
  endif
  return self._chunk.then({
  \ chunk -> len(chunk) >=# a:n ?
  \           s:_update_chunk_n(self, chunk, a:n) :
  \           s:_wait_until_next_msg(self).then({
  \             -> s:_read(self, a:n)
  \           })
  \})
endfunction

function! s:_update_chunk_n(self, chunk, n) abort
  let self = a:self
  let self._chunk = s:P.resolve(a:chunk[a:n :])
  return a:chunk[: a:n-1]
endfunction

function! s:_read_until(self, needle) abort
  let self = a:self
  return self._chunk.then({
  \ chunk -> {
  \   idx -> idx isnot# -1 ?
  \           s:_update_chunk_until(self, chunk, idx, a:needle) :
  \           s:_wait_until_next_msg(self).then({
  \             -> s:_read_until(self, a:needle)
  \           })
  \ }(stridx(chunk, a:needle))
  \})
endfunction

function! s:_update_chunk_until(self, chunk, idx, needle) abort
  let self = a:self
  if a:idx is# 0
    " a:chunk starts with a:needle
    let self._chunk = s:P.resolve(a:chunk[strlen(a:needle) :])
    return s:P.resolve('')
  else
    " a:chunk has a:needle in the middle
    let self._chunk = s:P.resolve(a:chunk[a:idx + strlen(a:needle) :])
    return s:P.resolve(a:chunk[: a:idx-1])
  endif
endfunction

function! s:_wait_until_next_msg(self) abort
  let self = a:self
  return s:P.new({
  \ resolve -> add(self._read_requests, resolve)
  \})
endfunction

function! s:_resolve(self, ...) abort
  let self = a:self
  call s:_finalize(self)
  call call(self._resolve, a:000)
endfunction

function! s:_reject(self, ...) abort
  let self = a:self
  call s:_finalize(self)
  call call(self._reject, a:000)
endfunction

function! s:_finalize(self) abort
  let self = a:self
  call timer_stop(self._timer)
  let self._timer = v:null
endfunction

function! s:_make_response(self, options) abort
  let self = a:self
  let response = s:_new_response()
  call extend(response, self._res, 'keep')
  let response.channel = self._channel
  return response
endfunction

function! s:_new_response() abort
  let response = {}
  let response.json = funcref('s:_Response_json')
  let response.close = funcref('s:_Response_close')
  return response
endfunction

function! s:_Response_json() abort dict
  return json_decode(self.content)
endfunction

function! s:_Response_close() abort dict
  call ch_close(self.channel)
endfunction


let &cpo = s:save_cpo
unlet s:save_cpo

" vim:set et ts=2 sts=2 sw=2 tw=0:
