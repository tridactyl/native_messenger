import std/[algorithm, json, locks, monotimes, nativesockets, net, os, sequtils,
  sha1, streams, strutils, sysrand, times]

when defined(posix):
    import std/posix
when defined(windows):
    import winlean

const
    CONTROL_PROTOCOL* = 1
    CONTROL_CAPABILITY* = "control-port-v1"
    MAX_CLI_FRAME* = 1024 * 1024
    MAX_NATIVE_FRAME* = 64 * 1024 * 1024
    AUTH_TIMEOUT_MS = 5_000
    CONTROL_TIMEOUT_MS = 30_000
    CLI_RESPONSE_TIMEOUT_MS = CONTROL_TIMEOUT_MS + 5_000
    PROBE_TIMEOUT_MS = 250
    MAX_CLIENTS = 32

type
    NativeFrameKind* = enum
        nfkMessage, nfkEof, nfkInvalid

    NativeFrame* = object
        kind*: NativeFrameKind
        payload*, error*: string

    ControlStart* = object
        ok*: bool
        instance*, error*: string

    StartupResult = object
        ok: bool
        port: int
        instance, error: string

    PendingSlot = object
        active: bool
        id: array[32, char]
        replies: Channel[string]

    WorkerArgs = object
        socket: Socket
        instance, token: string
        index: int

    SocketFrameKind = enum
        sfkMessage, sfkEof, sfkInvalid

    SocketFrame = object
        kind: SocketFrameKind
        payload, error: string

    ServerAuth = enum
        saAuthenticated, saUnavailable, saInvalid

    DiscoveryRecord = object
        path, instance, token: string
        port, pid: int

var
    bridgeInitialized = false
    nativeWriteLock, stateLock: Lock
    startupChannel: Channel[StartupResult]
    pendingSlots: array[MAX_CLIENTS, PendingSlot]
    workerDone: array[MAX_CLIENTS, bool]
    listenerThread: Thread[void]
    listenerStarted, listenerExited, stopRequested: bool
    stopIsDisconnect: bool
    listenerPort: int
    activeInstance: string

func frameHeader(length: int): string =
    let value = uint32(length)
    result = newString(4)
    result[0] = char(value and 0xff)
    result[1] = char((value shr 8) and 0xff)
    result[2] = char((value shr 16) and 0xff)
    result[3] = char((value shr 24) and 0xff)

func frameLength(header: string): uint32 =
    uint32(header[0].ord) or
      (uint32(header[1].ord) shl 8) or
      (uint32(header[2].ord) shl 16) or
      (uint32(header[3].ord) shl 24)

proc nativeFrameHeader(length: int): string =
    var value = uint32(length)
    result = newString(sizeof(value))
    copyMem(addr result[0], addr value, sizeof(value))

proc nativeFrameLength(header: string): uint32 =
    copyMem(addr result, unsafeAddr header[0], sizeof(result))

proc readStreamExact(stream: Stream, size: int): tuple[ok, eof: bool,
        data: string] =
    result.data = newString(size)
    var offset = 0
    while offset < size:
        let count = stream.readData(addr result.data[offset], size - offset)
        if count == 0:
            result.eof = offset == 0
            result.data.setLen(offset)
            return
        offset += count
    result.ok = true

proc readNativeFrame*(stream: Stream): NativeFrame =
    let header = readStreamExact(stream, 4)
    if header.eof:
        result.kind = nfkEof
        return
    if not header.ok:
        result.kind = nfkInvalid
        result.error = "truncated native message header"
        return

    let size = nativeFrameLength(header.data)
    if size == 0:
        result.kind = nfkEof
    elif size > MAX_NATIVE_FRAME.uint32 or size.uint64 > high(int).uint64:
        result.kind = nfkInvalid
        result.error = "native message exceeds maximum frame length"
    else:
        let payload = readStreamExact(stream, size.int)
        if payload.ok:
            result.kind = nfkMessage
            result.payload = payload.data
        else:
            result.kind = nfkInvalid
            result.error = "truncated native message payload"

proc writeNative*(payload: string): bool {.gcsafe.} =
    if payload.len.uint64 > high(uint32).uint64:
        stderr.writeLine("Native response exceeds the framing limit")
        return false

    let framed = nativeFrameHeader(payload.len) & payload
    acquire(nativeWriteLock)
    try:
        let written = stdout.writeBuffer(unsafeAddr framed[0], framed.len)
        flushFile(stdout)
        result = written == framed.len
    except IOError:
        result = false
    finally:
        release(nativeWriteLock)

proc initControlBridge*() =
    if bridgeInitialized:
        return
    initLock(nativeWriteLock)
    initLock(stateLock)
    startupChannel.open()
    for slot in pendingSlots.mitems:
        slot.replies.open()
    bridgeInitialized = true

proc randomHex(byteCount: int): string =
    const digits = "0123456789abcdef"
    var bytes = newSeq[byte](byteCount)
    if not urandom(bytes):
        raise newException(OSError, "secure random number generation failed")
    result = newString(byteCount * 2)
    for index, value in bytes:
        result[index * 2] = digits[int(value shr 4)]
        result[index * 2 + 1] = digits[int(value and 0x0f)]

func constantTimeEqual(left, right: string): bool =
    if left.len != right.len:
        return false
    var difference = 0
    for index in 0 ..< left.len:
        difference = difference or (left[index].ord xor right[index].ord)
    difference == 0

func isHex(value: string, length: int): bool =
    if value.len != length:
        return false
    for character in value:
        if character notin {'0'..'9', 'a'..'f'}:
            return false
    true

proc discoveryDirectory(): string =
    getCacheDir() / "tridactyl" / "native-control"

proc removeRecord(path: string) =
    if path.len == 0:
        return
    try:
        if fileExists(path):
            removeFile(path)
    except OSError:
        discard

proc processMayExist(pid: int): bool =
    if pid <= 0:
        return false
    when defined(posix):
        result = kill(Pid(pid), 0) == 0 or errno == EPERM
    elif defined(windows):
        let process = openProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), 0,
          DWORD(pid))
        if process != 0:
            discard closeHandle(process)
            result = true
        else:
            result = getLastError() != 87 # ERROR_INVALID_PARAMETER
    else:
        result = true

proc removeRecordIfDead(record: DiscoveryRecord) =
    if not processMayExist(record.pid):
        removeRecord(record.path)

proc publishRecord(instance, token: string, port: int): string =
    when defined(posix):
        let previousMask = umask(Mode(0o077))
        defer: discard umask(previousMask)

    let directory = discoveryDirectory()
    createDir(directory)
    when defined(posix):
        setFilePermissions(directory, {fpUserRead, fpUserWrite, fpUserExec})

    result = directory / (instance & ".json")
    let temporary = result & ".tmp"
    let record = %*{
        "protocol": CONTROL_PROTOCOL,
        "instance": instance,
        "port": port,
        "token": token,
        "pid": getCurrentProcessId()
    }
    try:
        writeFile(temporary, $record)
        when defined(posix):
            setFilePermissions(temporary, {fpUserRead, fpUserWrite})
        moveFile(temporary, result)
    except:
        removeRecord(temporary)
        removeRecord(result)
        raise

proc remainingTimeout(started: MonoTime, timeout: int): int =
    timeout - int((getMonoTime() - started).inMilliseconds)

proc shouldStop(): tuple[stop, disconnected: bool] =
    acquire(stateLock)
    result = (stopRequested, stopIsDisconnect)
    release(stateLock)

proc recvExact(socket: Socket, size, timeout: int,
        stopAware: bool): tuple[ok, eof: bool, data, error: string] =
    result.data = newStringOfCap(size)
    let started = getMonoTime()
    while result.data.len < size:
        if stopAware and shouldStop().stop:
            result.eof = true
            return
        let remaining = remainingTimeout(started, timeout)
        if remaining <= 0:
            result.error = "request timed out"
            return
        try:
            let receiveTimeout = if stopAware: min(remaining, 100) else: remaining
            let chunk = socket.recv(size - result.data.len, receiveTimeout)
            if chunk.len == 0:
                result.eof = result.data.len == 0
                if not result.eof:
                    result.error = "truncated frame"
                return
            result.data.add(chunk)
        except TimeoutError:
            if not stopAware:
                result.error = "request timed out"
                return
        except OSError:
            result.error = "connection closed"
            return
    result.ok = true

proc recvSocketFrame(socket: Socket, timeout: int,
        stopAware = false): SocketFrame =
    let header = recvExact(socket, 4, timeout, stopAware)
    if header.eof:
        result.kind = sfkEof
        return
    if not header.ok:
        result.kind = sfkInvalid
        result.error = header.error
        return

    let size = frameLength(header.data)
    if size == 0 or size > MAX_CLI_FRAME.uint32:
        result.kind = sfkInvalid
        result.error = "invalid frame length"
        return

    let payload = recvExact(socket, size.int, timeout, stopAware)
    if payload.ok:
        result.kind = sfkMessage
        result.payload = payload.data
    else:
        result.kind = sfkInvalid
        result.error = payload.error

proc sendSocketFrame(socket: Socket, payload: string) =
    if payload.len > MAX_CLI_FRAME:
        raise newException(ValueError, "response exceeds maximum frame length")
    let framed = frameHeader(payload.len) & payload
    let descriptor = socket.getFd()
    descriptor.setBlocking(false)
    defer:
        try:
            descriptor.setBlocking(true)
        except OSError:
            discard

    let started = getMonoTime()
    var offset = 0
    while offset < framed.len:
        if remainingTimeout(started, AUTH_TIMEOUT_MS) <= 0:
            raise newException(TimeoutError, "response timed out")
        let sent = socket.send(unsafeAddr framed[offset], framed.len - offset)
        if sent > 0:
            offset += sent
        elif sent == 0:
            raise newException(IOError, "connection closed")
        else:
            let error = osLastError()
            let retryable =
                when defined(windows):
                    error.int32 in [WSAEINTR, WSAEWOULDBLOCK]
                else:
                    error.int32 in [EINTR, EWOULDBLOCK, EAGAIN]
            if not retryable:
                raiseOSError(error)
            sleep(1)

func errorResponse(message: string): string =
    $(%*{"protocol": CONTROL_PROTOCOL, "ok": false, "error": message})

proc setPending(index: int, id: string) =
    acquire(stateLock)
    while pendingSlots[index].replies.tryRecv().dataAvailable:
        discard
    pendingSlots[index].active = true
    for idIndex in 0 ..< pendingSlots[index].id.len:
        pendingSlots[index].id[idIndex] = id[idIndex]
    release(stateLock)

proc clearPending(index: int, id: string) =
    acquire(stateLock)
    if pendingSlots[index].active:
        var matches = id.len == pendingSlots[index].id.len
        for idIndex in 0 ..< pendingSlots[index].id.len:
            matches = matches and pendingSlots[index].id[idIndex] == id[idIndex]
        if matches:
            pendingSlots[index].active = false
    release(stateLock)

proc waitForExtension(index: int): string =
    let started = getMonoTime()
    while remainingTimeout(started, CONTROL_TIMEOUT_MS) > 0:
        let stopping = shouldStop()
        if stopping.stop:
            if stopping.disconnected:
                return errorResponse("extension disconnected")
            return errorResponse("control endpoint disabled")

        let received = pendingSlots[index].replies.tryRecv()
        if received.dataAvailable:
            return received.msg
        sleep(10)
    errorResponse("extension response timed out")

func controlProof(token, challenge: string): string =
    $secureHash(token & challenge)

proc validCliRequest(node: JsonNode, token: string): bool =
    node.kind == JObject and
      node.hasKey("protocol") and node["protocol"].kind == JInt and
      node["protocol"].getBiggestInt == CONTROL_PROTOCOL and
      node.hasKey("token") and node["token"].kind == JString and
      constantTimeEqual(node["token"].getStr, token) and
      node.hasKey("operation") and node["operation"].kind == JString and
      node["operation"].getStr == "ex" and
      node.hasKey("command") and node["command"].kind == JString

proc handleClient(socket: Socket, instance, token: string, index: int) =
    let challengeFrame = recvSocketFrame(socket, AUTH_TIMEOUT_MS,
      stopAware = true)
    if challengeFrame.kind == sfkEof:
        return
    if challengeFrame.kind == sfkInvalid:
        sendSocketFrame(socket, errorResponse(challengeFrame.error))
        return

    var challenge: JsonNode
    try:
        challenge = parseJson(challengeFrame.payload)
    except JsonParsingError:
        sendSocketFrame(socket, errorResponse("invalid challenge"))
        return
    if challenge.kind != JObject or
      not challenge.hasKey("protocol") or challenge["protocol"].kind != JInt or
      challenge["protocol"].getBiggestInt != CONTROL_PROTOCOL or
      not challenge.hasKey("challenge") or challenge["challenge"].kind != JString or
      not isHex(challenge["challenge"].getStr, 32):
        sendSocketFrame(socket, errorResponse("invalid challenge"))
        return
    sendSocketFrame(socket, $(%*{
        "protocol": CONTROL_PROTOCOL,
        "instance": instance,
        "proof": controlProof(token, challenge["challenge"].getStr)
    }))

    let incoming = recvSocketFrame(socket, AUTH_TIMEOUT_MS, stopAware = true)
    if incoming.kind == sfkEof:
        return
    if incoming.kind == sfkInvalid:
        sendSocketFrame(socket, errorResponse(incoming.error))
        return

    var request: JsonNode
    try:
        request = parseJson(incoming.payload)
    except JsonParsingError:
        sendSocketFrame(socket, errorResponse("invalid request"))
        return
    if not validCliRequest(request, token):
        sendSocketFrame(socket, errorResponse("authentication failed"))
        return

    let id = randomHex(16)
    let nativeRequest = %*{
        "type": "control.request",
        "protocol": CONTROL_PROTOCOL,
        "id": id,
        "operation": "ex",
        "command": request["command"].getStr
    }
    setPending(index, id)
    defer: clearPending(index, id)
    if not writeNative($nativeRequest):
        sendSocketFrame(socket, errorResponse("extension disconnected"))
        return
    sendSocketFrame(socket, waitForExtension(index))

proc clientMain(arguments: WorkerArgs) {.thread.} =
    try:
        handleClient(arguments.socket, arguments.instance, arguments.token,
          arguments.index)
    except CatchableError:
        try:
            sendSocketFrame(arguments.socket, errorResponse("control request failed"))
        except CatchableError:
            discard
    finally:
        arguments.socket.close()
        acquire(stateLock)
        workerDone[arguments.index] = true
        release(stateLock)

proc listenerMain() {.thread.} =
    var
        server: Socket
        recordPath = ""
        announced = false
        workers: array[MAX_CLIENTS, Thread[WorkerArgs]]
        workerUsed: array[MAX_CLIENTS, bool]
    try:
        let token = randomHex(32)
        let instance = randomHex(16)
        server = newSocket(buffered = false)
        server.bindAddr(Port(0), "127.0.0.1")
        server.listen()
        let (_, boundPort) = server.getLocalAddr()
        let port = boundPort.int
        recordPath = publishRecord(instance, token, port)
        startupChannel.send(StartupResult(ok: true, port: port,
          instance: instance))
        announced = true

        while not shouldStop().stop:
            var client: Socket
            server.accept(client)
            if shouldStop().stop:
                client.close()
                break

            for index in 0 ..< MAX_CLIENTS:
                if workerUsed[index]:
                    acquire(stateLock)
                    let done = workerDone[index]
                    release(stateLock)
                    if done:
                        joinThread(workers[index])
                        workerUsed[index] = false

            var workerIndex = -1
            for index in 0 ..< MAX_CLIENTS:
                if not workerUsed[index]:
                    workerIndex = index
                    break
            if workerIndex < 0:
                client.close()
                continue

            acquire(stateLock)
            workerDone[workerIndex] = false
            release(stateLock)
            try:
                createThread(workers[workerIndex], clientMain,
                  WorkerArgs(socket: client, instance: instance, token: token,
                    index: workerIndex))
                workerUsed[workerIndex] = true
            except CatchableError:
                client.close()
    except CatchableError:
        if not announced:
            startupChannel.send(StartupResult(ok: false,
              error: "could not start the control endpoint"))
        else:
            stderr.writeLine("Control endpoint stopped unexpectedly")
    finally:
        acquire(stateLock)
        stopRequested = true
        release(stateLock)
        if server != nil:
            server.close()
        removeRecord(recordPath)
        for index in 0 ..< MAX_CLIENTS:
            if workerUsed[index]:
                joinThread(workers[index])
        acquire(stateLock)
        listenerExited = true
        release(stateLock)

proc listenerHasExited(): bool =
    acquire(stateLock)
    result = listenerExited
    release(stateLock)

proc startControl*(): ControlStart =
    if listenerStarted and not listenerHasExited():
        return ControlStart(ok: true, instance: activeInstance)
    if listenerStarted:
        joinThread(listenerThread)
        listenerStarted = false

    acquire(stateLock)
    stopRequested = false
    stopIsDisconnect = false
    listenerExited = false
    release(stateLock)
    try:
        createThread(listenerThread, listenerMain)
        listenerStarted = true
    except CatchableError:
        return ControlStart(error: "could not create the control thread")

    let startup = startupChannel.recv()
    if not startup.ok:
        joinThread(listenerThread)
        listenerStarted = false
        return ControlStart(error: startup.error)

    listenerPort = startup.port
    activeInstance = startup.instance
    ControlStart(ok: true, instance: startup.instance)

proc wakeListener(port: int) =
    if port == 0:
        return
    var socket: Socket
    try:
        socket = newSocket(buffered = false)
        socket.connect("127.0.0.1", Port(port), timeout = PROBE_TIMEOUT_MS)
    except CatchableError:
        discard
    finally:
        if socket != nil:
            socket.close()

proc stopControl*(extensionDisconnected = false) =
    if not listenerStarted:
        return
    acquire(stateLock)
    stopRequested = true
    stopIsDisconnect = extensionDisconnected
    release(stateLock)
    wakeListener(listenerPort)
    joinThread(listenerThread)
    listenerStarted = false
    listenerPort = 0
    activeInstance = ""

proc deliverControlResponse*(id, payload: string): bool =
    if id.len != pendingSlots[0].id.len:
        return false
    acquire(stateLock)
    var selected = -1
    for index in 0 ..< MAX_CLIENTS:
        var matches = pendingSlots[index].active
        for idIndex in 0 ..< pendingSlots[index].id.len:
            matches = matches and pendingSlots[index].id[idIndex] == id[idIndex]
        if matches:
            selected = index
            break
    if selected >= 0:
        pendingSlots[selected].replies.send(payload)
        result = true
    release(stateLock)

proc loadRecords(): seq[DiscoveryRecord] =
    let directory = discoveryDirectory()
    if not dirExists(directory):
        return
    for path in walkFiles(directory / "*.json"):
        try:
            let node = parseFile(path)
            if node.kind != JObject or
              not node.hasKey("protocol") or node["protocol"].kind != JInt or
              node["protocol"].getBiggestInt != CONTROL_PROTOCOL or
              not node.hasKey("instance") or node["instance"].kind != JString or
              not node.hasKey("token") or node["token"].kind != JString or
              not node.hasKey("port") or node["port"].kind != JInt or
              not node.hasKey("pid") or node["pid"].kind != JInt:
                raise newException(ValueError, "invalid discovery record")
            let port = node["port"].getBiggestInt
            let pid = node["pid"].getBiggestInt
            if port < 1 or port > 65_535 or pid < 1 or
              pid > BiggestInt(high(int32)):
                raise newException(ValueError, "invalid discovery record")
            let record = DiscoveryRecord(
                path: path,
                instance: node["instance"].getStr,
                token: node["token"].getStr,
                port: port.int,
                pid: pid.int,
            )
            if not isHex(record.instance, 32) or not isHex(record.token, 64) or
              path.extractFilename != record.instance & ".json":
                raise newException(ValueError, "invalid discovery record")
            result.add(record)
        except CatchableError:
            removeRecord(path)

proc authenticateServer(socket: Socket, record: DiscoveryRecord,
        timeout = AUTH_TIMEOUT_MS): ServerAuth =
    let challenge = randomHex(16)
    try:
        sendSocketFrame(socket, $(%*{
            "protocol": CONTROL_PROTOCOL,
            "challenge": challenge
        }))
    except CatchableError:
        return saUnavailable
    let responseFrame = recvSocketFrame(socket, timeout)
    if responseFrame.kind == sfkEof:
        return saUnavailable
    if responseFrame.kind != sfkMessage:
        return saUnavailable
    var response: JsonNode
    try:
        response = parseJson(responseFrame.payload)
    except JsonParsingError:
        return saInvalid
    if response.kind == JObject and
      response.hasKey("protocol") and response["protocol"].kind == JInt and
      response["protocol"].getBiggestInt == CONTROL_PROTOCOL and
      response.hasKey("instance") and response["instance"].kind == JString and
      response["instance"].getStr == record.instance and
      response.hasKey("proof") and response["proof"].kind == JString and
      constantTimeEqual(response["proof"].getStr,
        controlProof(record.token, challenge)):
        saAuthenticated
    else:
        saInvalid

proc canConnect(record: DiscoveryRecord): bool =
    var socket: Socket
    try:
        socket = newSocket(buffered = false)
        socket.connect("127.0.0.1", Port(record.port), timeout = PROBE_TIMEOUT_MS)
        let authenticated = authenticateServer(socket, record,
          PROBE_TIMEOUT_MS)
        result = authenticated == saAuthenticated
        if authenticated == saInvalid:
            removeRecord(record.path)
        elif authenticated == saUnavailable:
            removeRecordIfDead(record)
    except CatchableError:
        removeRecordIfDead(record)
    finally:
        if socket != nil:
            socket.close()

proc liveRecords(records: seq[DiscoveryRecord]): seq[DiscoveryRecord] =
    for record in records:
        if canConnect(record):
            result.add(record)
    result.sort(proc(left, right: DiscoveryRecord): int =
      cmp(left.instance, right.instance))

proc chooseRecord(selector: string): tuple[ok: bool, record: DiscoveryRecord,
        error: string] =
    var records = loadRecords()
    if selector.len > 0:
        records = records.filterIt(it.instance.startsWith(selector))
    records = liveRecords(records)
    if selector.len > 0:
        if records.len == 0:
            return (false, DiscoveryRecord(), "no native host matches instance " & selector)
        if records.len > 1:
            return (false, DiscoveryRecord(), "instance selector is ambiguous")
    elif records.len == 0:
        return (false, DiscoveryRecord(), "no opted-in native host found")
    elif records.len > 1:
        var instances: seq[string]
        for record in records:
            instances.add(record.instance)
        return (false, DiscoveryRecord(),
          "multiple opted-in native hosts found; use --instance with one of: " &
          instances.join(", "))
    (true, records[0], "")

proc runCli*(command, selector: string): int =
    let selected = chooseRecord(selector)
    if not selected.ok:
        stderr.writeLine(selected.error)
        return 1

    var socket: Socket
    try:
        socket = newSocket(buffered = false)
        socket.connect("127.0.0.1", Port(selected.record.port),
          timeout = PROBE_TIMEOUT_MS)
        if authenticateServer(socket, selected.record) != saAuthenticated:
            stderr.writeLine("selected native host failed authentication")
            return 1
        let request = %*{
            "protocol": CONTROL_PROTOCOL,
            "token": selected.record.token,
            "operation": "ex",
            "command": command
        }
        sendSocketFrame(socket, $request)
        let responseFrame = recvSocketFrame(socket, CLI_RESPONSE_TIMEOUT_MS)
        if responseFrame.kind != sfkMessage:
            stderr.writeLine(if responseFrame.error.len > 0:
              responseFrame.error else: "control connection closed")
            return 1

        let response = parseJson(responseFrame.payload)
        if response.kind != JObject or
          not response.hasKey("protocol") or response["protocol"].kind != JInt or
          response["protocol"].getBiggestInt != CONTROL_PROTOCOL or
          not response.hasKey("ok") or response["ok"].kind != JBool:
            stderr.writeLine("invalid control response")
            return 1
        if not response["ok"].getBool:
            if response.hasKey("error") and response["error"].kind == JString:
                stderr.writeLine(response["error"].getStr)
            else:
                stderr.writeLine("control request failed")
            return 1
        if response.hasKey("result"):
            if response["result"].kind == JString:
                stdout.writeLine(response["result"].getStr)
            else:
                stdout.writeLine($response["result"])
        result = 0
    except CatchableError:
        stderr.writeLine("could not contact the selected native host")
        result = 1
    finally:
        if socket != nil:
            socket.close()
