let s:save_cpo = &cpo
set cpo&vim


function! s:_vital_depends() abort
  return ['Async.Promise', 'Web.URI', 'Request']
endfunction

function! s:_vital_loaded(V) abort
  let s:P = a:V.import('Async.Promise')
  let s:URI = a:V.import('Web.URI')
  let s:Request = a:V.import('Request')

  let s:CRLF = "\r\n"

  let s:STATE_NOT_CONNECTED = 0
  let s:STATE_CONNECTING = 1
  let s:STATE_MESSAGING = 2
endfunction


function! s:new() abort
  let self = {}
  let self._interval = 200
  let self._events = {}
  let self._connected = 0
  let self._connected_info = {}
  let self._state = s:STATE_NOT_CONNECTED
  let self.connect = funcref('s:_WebSocket_connect')
  let self.close = funcref('s:_WebSocket_close')
  let self.is_connected = funcref('s:_WebSocket_is_connected')
  let self.on = funcref('s:_WebSocket_on')
  let self.send = funcref('s:_WebSocket_send')
  return self
endfunction

function! s:_WebSocket_connect(uri) abort dict
  if self._connected
    return
  endif
  let uri = a:uri
  if type(uri) is# v:t_string
    let uri = s:URI.new(uri)
  endif
  if type(uri) isnot# v:t_dict || type(uri.scheme) isnot# v:t_func
    throw 'WebSocket: uri is not URI object'
  endif
  if uri.scheme() isnot# 'ws'
    throw 'WebSocket: connect(): not ws:// URI was given: ' . uri.to_string()
  endif

  " TODO: Generate Sec-WebSocket-Key
  return s:Request.get(uri, {
  \ 'timer_interval': 200,
  \ 'headers': {
  \   'Upgrade': 'websocket',
  \   'Connection': 'Upgrade',
  \   'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
  \   'Sec-WebSocket-Version': '13',
  \ }
  \}).then({
  \ res -> s:_complete_handshake(self, res)
  \})
endfunction

" TODO: Check response header "Sec-WebSocket-Accept"
function! s:_complete_handshake(self, res) abort
  let self = a:self
  let channel = a:res.channel

  call s:_do_event(self, 'open', [])

  let self._connected_info = {}
  let self._connected_info.channel = channel
  let self._connected_info.timer = timer_start(
  \ self._interval, {-> ch_status(channel)}, {'repeat': -1}
  \)

  call ch_setoptions(channel, {'callback': {_, msg -> s:_parse_chunk(self, msg)}})

  let self._connected = 1
endfunction

function! s:_do_event(self, event, args) abort
  for l:F in get(a:self._events, a:event, [])
    call call(l:F, a:args)
  endfor
endfunction

function! s:_parse_chunk(self, msg) abort
  let self = a:self

  " TODO: unpack frame

  call s:_do_event(self, 'message', [a:msg])
endfunction

function! s:_WebSocket_close() abort dict
  if !self._connected
    return
  endif
  " TODO: Send FIN frame?
  if has_key(self._connected_info, 'timer')
    call timer_stop(self._connected_info.timer)
  endif
  call ch_close(self._connected_info.channel)
  let self._connected_info = {}
  call s:_do_event(self, 'close', [])
endfunction

function! s:_WebSocket_is_connected() abort dict
  return self._connected
endfunction

function! s:_WebSocket_on(event, f) abort dict
  let t = type(a:f)
  if t isnot# v:t_string && t isnot# v:t_func
    throw 'WebSocket: on(): String nor Funcref was given'
  endif
  if has_key(self._events, a:event)
    let self._events[a:event] += [a:f]
  else
    let self._events[a:event] = [a:f]
  endif
endfunction

function! s:_WebSocket_send(value) abort dict
  if !self._connected
    return
  endif
endfunction


let &cpo = s:save_cpo
unlet s:save_cpo

" vim:set et ts=2 sts=2 sw=2 tw=0:
