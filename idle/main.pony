use "net"
use "net/ssl"
use "json"
use "files"
use "collections"
use "time"
use "lib:c"
use "signals"
use "bureaucracy"

primitive IMAPCAPABILITY
primitive IMAPLOGIN
primitive IMAPSELECT
primitive IMAPIDLE
primitive IMAPLIST
primitive IMAPCLOSE
primitive IMAPLOGOUT
type Command is (IMAPCAPABILITY | IMAPLOGIN | IMAPSELECT | IMAPIDLE | IMAPLIST | IMAPCLOSE | IMAPLOGOUT)

actor Main
  new create(env:Env) =>
    let timers = Timers
    let custodian = Custodian
    let system = System.create(timers)
    custodian(system)

    let filename = try env.args(1) else "idle.json" end
    let contents =
      try
        let file = File.open(FilePath(env.root, filename))
        file.read_string(file.size())
      else
        ""
      end

    env.out.print("Reading " + filename)
    let json: JsonDoc = JsonDoc
    try
      env.out.print("Parsing " + filename)
      json.parse(contents)
      env.out.print("Parsed " + filename)

      let idlers = recover iso Array[Idler] end
      let config = json.data as JsonArray
      for entry in config.data.values() do
        let imap = (entry as JsonObject).data
        let name = imap("name") as String
        let host = imap("host") as String
        let userid = imap("userid") as String
        let password = imap("password") as String
        let inbox = imap("inbox") as String
        let command = imap("command") as String
        let idler = Idler(env, system, timers, name, host, userid, password, inbox, command)
        idler.connect()
        custodian(idler)
        idlers.push(idler)
        env.out.print("Started Idler for " + name)
      end
      // SIGQUIT (Ctrl+\) is used to force a fetch of mail
      SignalHandler(recover FetchMailHandler(consume idlers) end, Sig.quit())

      // SIGINT (Ctrl+C) is used for graceful exit
      SignalHandler(recover QuitHandler(custodian) end, Sig.int())
    end

class FetchMailHandler is SignalNotify
  let _idlers:Array[Idler]

  new create(idlers:Array[Idler]) =>
    _idlers = idlers

  fun ref apply(count: U32): Bool =>
    for idler in _idlers.values() do
      idler.force_fetch()
    end
    true

class QuitHandler is SignalNotify
  let _custodian:Custodian

  new create(custodian:Custodian) =>
    _custodian = custodian

  fun ref apply(count: U32): Bool =>
    _custodian.dispose()
    false

class ResponseBuilder is TCPConnectionNotify
  let _buffer:Buffer = Buffer
  let _idler:Idler
  let _env:Env

  new iso create(env:Env, idler:Idler) =>
    _idler = idler
    _env = env

  fun ref connected(conn: TCPConnection ref) => 
    _env.out.print("connected")
    _idler.connected(conn)

  fun ref connect_failed(conn: TCPConnection ref) => 
    _env.out.print("connect_failed")
    _idler.connect_failed()

  fun ref auth_failed(conn: TCPConnection ref) =>
    _env.out.print("auth_failed")
    None

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso) =>
    _buffer.append(consume data)
    try
      while true do
        _idler.got_line(_buffer.line())
      end
    end

  fun ref connecting(conn: TCPConnection ref, count: U32) =>
    _env.out.print("connecting")
    None

  fun ref closed(conn: TCPConnection ref) =>
    _env.out.print("closed")
    _idler.closed()
    None

trait tag Action
  be got_line(s:String, idler: Idler) => idler.on_command(s)
  be command_continue(s:String, idler: Idler) => None
  be command_line(s:String, idler: Idler) => None
  be command_end(s:String, idler: Idler) => None
  be dispose() => None

actor WaitForConnection is Action
  be got_line(s:String, idler: Idler) =>
    idler.on_connected(s)

actor WaitForLogin is Action
  be command_end(s:String, idler: Idler) =>
    idler.send_select()

actor WaitForSelect is Action
  be command_end(s:String, idler: Idler) =>
    idler.start_idling()

actor WaitForIdle is Action
  let _timers:Timers
  let _timer:Timer tag

  new create(timers:Timers, idler:Idler) =>
    _timers = timers
    let timer = Timer(object iso
                        let _idler:Idler = idler
                        fun ref apply(timer:Timer, count:U64):Bool =>
                          _idler.stop_idling()
                          false
                        fun ref cancel(timer:Timer) => None
                      end, 1_000_000_000 * 60 * 5, 0) // 5 Minute timeout
    _timer = timer
    timers(consume timer)
 
  be command_end(s:String, idler: Idler) =>
    _timers.cancel(_timer)
    idler.start_idling()

  be dispose() =>
    _timers.cancel(_timer)

actor WaitForLogout is Action
  be command_end(s:String, idler: Idler) =>
    idler.on_logout()

actor Idler
  let _account:String
  let _server:String
  let _user:String
  let _password:String
  let _folder:String
  let _command:String
  var _conn:(TCPConnection | None) = None
  let _env:Env
  let _system:System
  let _timers:Timers
  var _count:U32 = 0
  var _action:Action = WaitForConnection
  var _commands:Map[U32, Action] = Map[U32, Action]

  new create(env:Env,system:System,timers:Timers,account:String,server:String, user:String, password:String, folder:String, command:String) =>
    _account = account
    _server = server
    _user = user
    _password = password
    _folder = folder
    _command = command
    _env = env
    _system = system
    _timers = timers

  fun cmd_name(cmd:Command): String =>
    match cmd
    | IMAPCAPABILITY => "CAPABILITY"
    | IMAPLOGIN => "LOGIN"
    | IMAPSELECT => "SELECT"
    | IMAPIDLE => "IDLE"
    | IMAPLIST => "LIST"
    | IMAPCLOSE => "CLOSE"
    | IMAPLOGOUT => "LOGOUT"
    else ""
    end
  
  be send_command(cmd:Command, action:Action, data:(String | None)) =>
    _count = _count + 1
    _action = action
    _commands.update(_count, action)
    let c:String = cmd_name(cmd)
    let tail:String = match data
            | (let s:String) => " " + s + "\r\n"
            | None => "\r\n"
            else ""
            end
    let s = _count.string() + " " + c + tail
    try
      (_conn as TCPConnection).write(s)
    else
      log("error sending [" + s + "]")
    end

  be connect() =>
    try
      let ctx = SSLContext.set_client_verify(false)
      let ssl = ctx.client(_server)

      _conn = TCPConnection(SSLConnection(ResponseBuilder(_env, this), consume ssl), _server, "993".string())
    else
      log("failed to connect")
    end

  be connected(conn:TCPConnection) =>
    log("server connected")

  be connect_failed() =>
    log("connect failed")

  be closed() =>
    log("closed")

  be got_line(s:String) =>
    _action.got_line(s, this)

  be on_connected(s:String) =>
    send_command(IMAPLOGIN, WaitForLogin, _user + " " + _password)

  be on_command(s:String) => 
    try
      if s(0) == '*' then
        on_command_untagged(s)
      elseif s(0) == '+' then
        _action.command_continue(s, this)
      else
        try
          let offset = s.find(" ")
          let tagg = s.substring(0, offset).u32()
          if s.at("OK", offset + 1) then
            _commands(tagg).command_end(s.substring(offset + 3, 0), this)
            _commands.remove(tagg)
          else
            _commands(tagg).command_line(s.substring(offset + 1, 0), this)
          end
        else
          on_command_unknown(s)
        end
      end
    else
      on_command_unknown(s)
    end
          
  be on_command_untagged(s:String) =>
    log("untagged command [" + s + "]")
    let exists:Bool = try 
                        s.find("EXISTS")
                        true
                      else
                        false
                      end
    if exists then 
      _system.run(_command)
    end
    if s.at("* BYE", 0) then
      try
        (_conn as TCPConnection).dispose()
        _env.out.print("Reconnecting to " + _account)
        connect()
      end
    end

  be on_command_unknown(s:String) =>
    log("unknown command [" + s + "]")

  be on_logout() => try (_conn as TCPConnection).dispose() end

  be log(s:String) => _env.out.print(_account + ": " + s)

  be start_idling() =>
    log("idling started")
    send_command(IMAPIDLE, WaitForIdle(_timers, this), None)

  be stop_idling() =>
    log("idling stopped")
    try
      (_conn as TCPConnection).write("DONE\r\n")
    end

  be send_select() =>
    send_command(IMAPSELECT, WaitForSelect, _folder)

  be force_fetch() =>
    log("Forcing fetch of mail")
    _system.run(_command)

  be dispose() =>
    log("disposing")
    try
        (_conn as TCPConnection).dispose()
    end
    for action in _commands.values() do
      action.dispose()
    end
    
actor System
  let _commands:Set[String] = Set[String]
  let _timer:Timer tag
  let _timers:Timers

  new create(timers:Timers) =>
    _timers = timers
    let timer = Timer(object iso
                        let _system:System = this
                        fun ref apply(timer:Timer, count:U64):Bool =>
                          _system.run_all() 
                          true
                        fun ref cancel(timer:Timer) => None
                      end, 0, 1_000_000_000 * 15) // 15 Second timeout
    _timer = timer
    _timers(consume timer)
 
  be run(s:String) =>
    _commands.set(s)

  be run_all() =>
    for v in _commands.values() do
      @system[None](v.cstring())
    end
    _commands.clear()

  be dispose() =>
    _timers.cancel(_timer)
   
