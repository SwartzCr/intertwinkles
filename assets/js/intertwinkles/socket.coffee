###
A SockJS client that works with express cookies and our room server to
initialize identification.

The client may be in one of many states, which are referenced as @state, and
triggered when the client enters that state.  The naming follows
SockJS.readyState's state naming, with the addition of 'identifying' and
'identified':
 - connecting: we're trying to establish the socket connection.
 - open: We have a socket connection, but haven't identified.
 - identifying: We're working on identifying using the session ID obtained from
   the express.sid cookie.
 - identified: We're identified. From now on, we should be able to send any app messages.
 - closing: We're working on shutting down the socket connection.
 - closed: The socket connection is closed.

On construction, the client tries to identify.  Probably best to listen for
"identified" to indicate that we have a working socket connection.

Takes a single 'url' argument in the constructor, which is where we should find
the sockjs server to connect to.  Default "/sockjs".

Uses Backbone.Events for event triggering.
###

class intertwinkles.SocketClient
  _.extend @prototype, Backbone.Events
  # Preserve state numbering
  CONNECTING: SockJS.CONNECTING # 0
  OPEN: SockJS.OPEN # 1
  IDENTIFYING: 4
  IDENTIFIED: 5
  CLOSING: SockJS.CLOSING # 2
  CLOSED: SockJS.CLOSED # 3

  # How long to wait before giving up on a connection
  FAIL_TIMEOUT: 1000 * 10

  constructor: (url="/sockjs") ->
    @state = @CLOSED
    @url = url
    @connect()

  connect: =>
    unless @_isReconnecting
      @_setConnectTimeout()
    if @state == @CLOSED
      unless @_isReconnecting
        @trigger "connecting", this
      @state = @CONNECTING
      @sock = new SockJS(@url)
      @sock.onopen = @_onOpen
      @sock.onmessage = @_onMessage
      @sock.onclose = @_onClose
      return true
    return false

  disconnect: =>
    if @sock?
      @sock.onopen = @sock.onmessage = @sock.onclose = null
      @sock.close()
    @sock = null
    @state = @CLOSED
    unless @_isReconnecting
      @trigger "closed", this

  _setConnectTimeout: =>
    clearTimeout(@_connectTimeout) if @_connectTimeout?
    @_connectTimeout = setTimeout(@_fail, @FAIL_TIMEOUT)

  _fail: =>
    @disconnect()
    @trigger "fail", this

  reconnect: =>
    unless @_isReconnecting
      @_isReconnecting = true
      @trigger "closed", this
      @trigger "reconnecting", this
      @_setConnectTimeout()
    @disconnect()
    @connect()

  identify: =>
    @state = @IDENTIFYING
    @send "identify", {session_id: $.cookie("express.sid")}
    if @_isReconnecting
      @trigger "reconnected", this
      @_isReconnecting = false

  isIdentified: =>
    return @state == @IDENTIFIED

  isAlive: =>
    return not @isFinished()

  isFinished: =>
    return @state == @CLOSING or @state == @CLOSED

  send: (route, data) =>
    data ?= {}
    @sock.send JSON.stringify({
      route: route
      body: data
    })

  _onOpen: =>
    @state = @OPEN
    @identify()
    @trigger "open", this
    clearTimeout(@_connectTimeout) if @_connectTimeout?

  _onMessage: (event) =>
    data = JSON.parse(event.data)
    { route, body } = data

    if route == "error"
      console.log "socket message: error", body

    if route == "identify"
      @state = @IDENTIFIED
      @session_id = body.session_id
      @trigger "identified", this
    else
      @trigger route, body

  _onClose: =>
    @reconnect()

socket_status_view_template = _.template("""
  <% if (state == "error") { %>
    Sorry, there has been a server error. <a href='' class='reload'>Reload?</a>
  <% } else if (state == "connecting") { %>
    Connecting ... <img src='/static/img/spinner.gif' />
  <% } else if (state == "reconnecting") { %>
    Reconnecting... <img src='/static/img/spinner.gif' />
  <% } else if (state == "fail") { %>
    Connection to the server lost. <a href='' class='reload'>Reload?</a>
  <% } else if (state == "ok") { %>
    Connected!
  <% } %>
""")

class intertwinkles.SocketStatusView extends Backbone.View
  template: socket_status_view_template
  initialize: (options) ->
    @socket = options.socket
    @socket.on "error",        => @render("error")
    @socket.on "connecting",   => @render("connecting")
    @socket.on "identified",   => @render("ok")
    @socket.on "reconnecting", => @render("reconnecting")
    @socket.on "fail",         => @render("fail")

  render: (state="hide") =>
    @$el.addClass("socket-status-view")
    @$el.removeClass(@prevState) if @prevState
    @$el.addClass(state)
    @prevState = state
    if state == "hide"
      @$el.hide()
    else if state == "ok"
      setTimeout (=> @$el.slideUp()), 300
    else
      if @$el.is(":hidden")
        @$el.slideDown()
    @$el.html(@template({state}))

intertwinkles.add_socket_status_view = (socket, state="connecting") ->
  status_view = new intertwinkles.SocketStatusView({socket})
  $("body").append(status_view.el)
  status_view.render(state)
  $(window).on "unload", -> status_view.remove()

intertwinkles.connect_socket = (cb) ->
  if intertwinkles.socket? and intertwinkles.socket.isAlive()
    intertwinkles.add_socket_status_view(intertwinkles.socket)
    if cb?
      if intertwinkles.socket.isIdentified()
        cb(intertwinkles.socket)
      else
        intertwinkles.socket.on "identified", cb
  else
    socket = new intertwinkles.SocketClient("/sockjs")
    intertwinkles.add_socket_status_view(socket)
    socket.once "identified", ->
      intertwinkles.socket = socket
      cb?(intertwinkles.socket)
