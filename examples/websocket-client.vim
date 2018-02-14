
" Run:
" 1. mkdir tmp
" 2. {chrome} --remote-debugging-port=9222 --no-first-run --no-default-browser-check --user-data-dir=tmp
"
" ref. https://developer.mozilla.org/ja/docs/Tools/Remote_Debugging/Chrome_Desktop


let s:V = vital#vital#new()
let s:Request = s:V.import('Request')
let s:WebSocket = s:V.import('WebSocket')
unlet s:V

let s:CHROME_PORT = 9222

function! s:run() abort
  let uri = 'http://localhost:' . s:CHROME_PORT . '/json'
  call s:Request.get(uri)
               \.then({res -> res.json()})
               \.then({
               \ tabs -> tabs[0].webSocketDebuggerUrl
               \}).then({
               \ ws_url -> s:start_websocket(ws_url)
               \}).catch({err -> execute('echom "failed:" string(err)', '')})
endfunction

function! s:start_websocket(ws_url) abort
  let ws = s:WebSocket.new()
  call ws.on('message', {msg -> execute('echom "received message" string(msg)', '')})
  call ws.on('open', {-> [
  \ execute('echom "opened"', ''),
  \ ws.send({'id': 1, 'method': 'Timeline.start'}),
  \]})
  call ws.on('close', {-> execute('echom "closed"', '')})
  call ws.connect(a:ws_url).catch({
  \ err -> execute('echom "WebSocket.connect(...).catch()" string(err)', '')
  \})
endfunction

call s:run()
