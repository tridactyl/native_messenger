import std/[algorithm, json, locks, monotimes, nativesockets, net, os, sequtils,
  strutils, sysrand, times]

when defined(posix):
    import std/posix
when defined(windows):
    import winlean

const
    CONTROL_PROTOCOL* = 1
    CONTROL_CAPABILITY* = "control-port-v1"
    MAX_CLI_LINE = 1024 * 1024
    CLIENT_TIMEOUT_MS = 1_000
    CONTROL_TIMEOUT_MS = 30_000
    CLI_RESPONSE_TIMEOUT_MS = CONTROL_TIMEOUT_MS + 5_000
    PROBE_TIMEOUT_MS = 250
    MAX_CLIENTS = 32

type
    ControlStart* = object
        ok*: bool
        instance*, error*: string

    WorkerArgs = object
        socket: Socket
        token: string
        index: int

    ListenerArgs = object
        server: Socket
        recordPath, token: string

    PendingSlot = object
        active: bool
        id: array[32, char]
        replies: Channel[string]

    DiscoveryRecord = object
        path, instance, token: string
        port: int
        pid: BiggestInt

    DiscoveryData = object
        protocol, port, pid: BiggestInt
        instance, token: string

var
    bridgeInitialized = false
    nativeWriteLock, stateLock: Lock
    pendingSlots: array[MAX_CLIENTS, PendingSlot]
    completedWorkers: Channel[int]
    listenerThread: Thread[ListenerArgs]
    listenerStarted, listenerExited, stopRequested, stopIsDisconnect: bool
    listenerPort: int
    activeInstance: string

proc writeNative*(payload: string): bool {.gcsafe.} =
    if payload.len.uint64 > high(uint32).uint64:
        stderr.writeLine("Native response exceeds the framing limit")
        return false

    var size = payload.len.uint32
    withLock nativeWriteLock:
        try:
            result = stdout.writeBuffer(addr size, sizeof(size)) == sizeof(size)
            if result and payload.len > 0:
                result = stdout.writeBuffer(unsafeAddr payload[0], payload.len) ==
                  payload.len
            flushFile(stdout)
        except IOError:
            result = false

proc initControlBridge*() =
    if bridgeInitialized:
        return
    initLock(nativeWriteLock)
    initLock(stateLock)
    completedWorkers.open()
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

func isHex(value: string, length: int): bool =
    value.len == length and value.allCharsInSet({'0'..'9', 'a'..'f'})

func constantTimeEqual(left, right: string): bool =
    if left.len != right.len:
        return false
    var difference = 0
    for index in 0 ..< left.len:
        difference = difference or (left[index].ord xor right[index].ord)
    difference == 0

proc discoveryDirectory(): string =
    getCacheDir() / "tridactyl" / "native-control"

proc removeRecord(path: string) =
    try:
        if path.len > 0 and fileExists(path):
            removeFile(path)
    except OSError:
        discard

proc processMayExist(pid: BiggestInt): bool =
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
    try:
        writeFile(temporary, $(%*{
            "protocol": CONTROL_PROTOCOL,
            "instance": instance,
            "port": port,
            "token": token,
            "pid": getCurrentProcessId()
        }))
        when defined(posix):
            setFilePermissions(temporary, {fpUserRead, fpUserWrite})
        moveFile(temporary, result)
    except:
        removeRecord(temporary)
        removeRecord(result)
        raise

proc remainingTimeout(started: MonoTime, timeout: int): int =
    timeout - int((getMonoTime() - started).inMilliseconds)

proc stopping(): tuple[stop, disconnected: bool] =
    withLock stateLock:
        result = (stopRequested, stopIsDisconnect)

proc errorResponse(message: string): string =
    $(%*{"protocol": CONTROL_PROTOCOL, "ok": false, "error": message})

func validProtocol(node: JsonNode): bool =
    node.kind == JObject and
      node{"protocol"}.getBiggestInt(-1) == CONTROL_PROTOCOL

proc sendLine(socket: Socket, payload: string) =
    if payload.len > MAX_CLI_LINE:
        raise newException(ValueError, "response exceeds maximum line length")
    let
        data = payload & "\n"
        descriptor = socket.getFd()
        started = getMonoTime()
    descriptor.setBlocking(false)
    defer:
        try:
            descriptor.setBlocking(true)
        except OSError:
            discard
    var offset = 0
    while offset < data.len:
        let sent = socket.send(unsafeAddr data[offset], data.len - offset)
        if sent > 0:
            offset += sent
        elif sent == 0:
            raise newException(IOError, "connection closed")
        else:
            let error = osLastError()
            let retryable =
                when defined(windows): error.int32 in [WSAEINTR, WSAEWOULDBLOCK]
                else: error.int32 in [EINTR, EWOULDBLOCK, EAGAIN]
            if not retryable:
                raiseOSError(error)
            if remainingTimeout(started, CLIENT_TIMEOUT_MS) <= 0:
                raise newException(TimeoutError, "response timed out")
            sleep(1)

proc receiveJson(socket: Socket, timeout: int): JsonNode =
    let line = socket.recvLine(timeout = timeout, maxLength = MAX_CLI_LINE)
    if line.len == 0:
        raise newException(IOError, "connection closed")
    if line.len > MAX_CLI_LINE:
        raise newException(ValueError, "request exceeds maximum line length")
    parseJson(line)

proc setPending(index: int, id: string) =
    while pendingSlots[index].replies.tryRecv().dataAvailable:
        discard
    withLock stateLock:
        pendingSlots[index].active = true
        for offset, character in id:
            pendingSlots[index].id[offset] = character

proc clearPending(index: int) =
    withLock stateLock:
        pendingSlots[index].active = false

proc waitForExtension(index: int): string =
    let started = getMonoTime()
    while remainingTimeout(started, CONTROL_TIMEOUT_MS) > 0:
        let state = stopping()
        if state.stop:
            return errorResponse(if state.disconnected: "extension disconnected"
              else: "control endpoint disabled")
        let received = pendingSlots[index].replies.tryRecv()
        if received.dataAvailable:
            return received.msg
        sleep(10)
    result = errorResponse("extension response timed out")

proc validRequest(node: JsonNode, token: string): bool =
    validProtocol(node) and constantTimeEqual(node{"token"}.getStr, token) and
      node{"operation"}.getStr == "ex" and node{"command"}.getStr.len > 0

proc handleClient(socket: Socket, token: string, index: int) =
    var request: JsonNode
    try:
        request = receiveJson(socket, CLIENT_TIMEOUT_MS)
    except CatchableError:
        sendLine(socket, errorResponse("invalid control request"))
        return
    if not validRequest(request, token):
        sendLine(socket, errorResponse("authentication failed"))
        return

    let id = randomHex(16)
    setPending(index, id)
    defer: clearPending(index)
    if not writeNative($(%*{
        "type": "control.request",
        "protocol": CONTROL_PROTOCOL,
        "id": id,
        "operation": "ex",
        "command": request["command"].getStr
    })):
        sendLine(socket, errorResponse("extension disconnected"))
        return
    sendLine(socket, waitForExtension(index))

proc clientMain(arguments: WorkerArgs) {.thread.} =
    try:
        handleClient(arguments.socket, arguments.token, arguments.index)
    except CatchableError:
        try:
            sendLine(arguments.socket,
              errorResponse("control request failed"))
        except CatchableError:
            discard
    finally:
        arguments.socket.close()
        completedWorkers.send(arguments.index)

proc listenerMain(arguments: ListenerArgs) {.thread.} =
    var
        workers: array[MAX_CLIENTS, Thread[WorkerArgs]]
        workerUsed: array[MAX_CLIENTS, bool]
    try:
        while not stopping().stop:
            var client: Socket
            arguments.server.accept(client)
            if stopping().stop:
                client.close()
                break

            while true:
                let completed = completedWorkers.tryRecv()
                if not completed.dataAvailable:
                    break
                if workerUsed[completed.msg]:
                    joinThread(workers[completed.msg])
                    workerUsed[completed.msg] = false

            let index = workerUsed.find(false)
            if index < 0:
                client.close()
                continue
            try:
                createThread(workers[index], clientMain,
                  WorkerArgs(socket: client, token: arguments.token,
                    index: index))
                workerUsed[index] = true
            except CatchableError:
                client.close()
    except CatchableError:
        stderr.writeLine("Control endpoint stopped unexpectedly")
    finally:
        withLock stateLock:
            stopRequested = true
        arguments.server.close()
        removeRecord(arguments.recordPath)
        for index in 0 ..< MAX_CLIENTS:
            if workerUsed[index]:
                joinThread(workers[index])
        withLock stateLock:
            listenerExited = true

proc listenerHasExited(): bool =
    withLock stateLock:
        result = listenerExited

proc startControl*(): ControlStart =
    if listenerStarted and not listenerHasExited():
        return ControlStart(ok: true, instance: activeInstance)
    if listenerStarted:
        joinThread(listenerThread)
        listenerStarted = false

    withLock stateLock:
        stopRequested = false
        stopIsDisconnect = false
        listenerExited = false
    var server: Socket
    var recordPath = ""
    try:
        let
            token = randomHex(32)
            instance = randomHex(16)
        server = newSocket(buffered = false)
        server.bindAddr(Port(0), "127.0.0.1")
        server.listen()
        let (_, port) = server.getLocalAddr()
        recordPath = publishRecord(instance, token, port.int)
        createThread(listenerThread, listenerMain, ListenerArgs(server: server,
          recordPath: recordPath, token: token))
        listenerStarted = true
        listenerPort = port.int
        activeInstance = instance
        result = ControlStart(ok: true, instance: instance)
    except CatchableError:
        if server != nil:
            server.close()
        removeRecord(recordPath)
        result.error = "could not start the control endpoint"

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
    withLock stateLock:
        stopRequested = true
        stopIsDisconnect = extensionDisconnected
    wakeListener(listenerPort)
    joinThread(listenerThread)
    listenerStarted = false
    listenerPort = 0
    activeInstance = ""

proc deliverControlResponse*(id, payload: string): bool =
    if id.len != pendingSlots[0].id.len:
        return false
    withLock stateLock:
        for slot in pendingSlots.mitems:
            var matches = slot.active
            for index, character in id:
                matches = matches and slot.id[index] == character
            if matches:
                slot.replies.send(payload)
                return true

proc loadRecords(): seq[DiscoveryRecord] =
    let directory = discoveryDirectory()
    if not dirExists(directory):
        return
    for path in walkFiles(directory / "*.json"):
        try:
            let data = parseFile(path).to(DiscoveryData)
            let maxPid =
                when defined(windows): BiggestInt(high(uint32))
                else: BiggestInt(high(int32))
            if data.protocol != CONTROL_PROTOCOL or data.port < 1 or
              data.port > 65_535 or data.pid < 1 or data.pid > maxPid:
                raise newException(ValueError, "invalid discovery record")
            let record = DiscoveryRecord(
                path: path,
                instance: data.instance,
                token: data.token,
                port: data.port.int,
                pid: data.pid,
            )
            if not isHex(record.instance, 32) or not isHex(record.token, 64) or
              path.extractFilename != record.instance & ".json":
                raise newException(ValueError, "invalid discovery record")
            if processMayExist(record.pid):
                result.add(record)
            else:
                removeRecord(path)
        except CatchableError:
            removeRecord(path)
    result.sort(proc(left, right: DiscoveryRecord): int =
      cmp(left.instance, right.instance))

proc chooseRecord(selector: string): tuple[ok: bool, record: DiscoveryRecord,
        error: string] =
    var records = loadRecords()
    if selector.len > 0:
        records = records.filterIt(it.instance.startsWith(selector))
        if records.len == 0:
            return (false, DiscoveryRecord(),
              "no native host matches instance " & selector)
        if records.len > 1:
            return (false, DiscoveryRecord(), "instance selector is ambiguous")
    elif records.len == 0:
        return (false, DiscoveryRecord(), "no opted-in native host found")
    elif records.len > 1:
        return (false, DiscoveryRecord(),
          "multiple opted-in native hosts found; use --instance with one of: " &
          records.mapIt(it.instance).join(", "))
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
        sendLine(socket, $(%*{
            "protocol": CONTROL_PROTOCOL,
            "token": selected.record.token,
            "operation": "ex",
            "command": command
        }))
        let response = receiveJson(socket, CLI_RESPONSE_TIMEOUT_MS)
        let ok = response{"ok"}
        if not validProtocol(response) or ok.isNil or ok.kind != JBool:
            stderr.writeLine("invalid control response")
            return 1
        if not response["ok"].getBool:
            stderr.writeLine(if response.hasKey("error") and
              response["error"].kind == JString: response["error"].getStr
              else: "control request failed")
            return 1
        if response.hasKey("result"):
            stdout.writeLine(if response["result"].kind == JString:
              response["result"].getStr else: $response["result"])
        result = 0
    except CatchableError:
        removeRecordIfDead(selected.record)
        stderr.writeLine("could not contact the selected native host")
        result = 1
    finally:
        if socket != nil:
            socket.close()
