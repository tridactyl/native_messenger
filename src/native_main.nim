import json
import options
import osproc
import streams
import os
import strutils
import posix
import regex
import base64
import control_bridge

# Third party stuff
import tempfile

# Platform-specific stuff
when defined(windows):
    import windows_helpers

const VERSION = "0.6.0"

type
    MessageRecv* = object
        cmd*, version*, content*, error*, command*, `var`*, file*, dir*, to*,
          `from`*, prefix*, path*, profiledir*, browsercmd*: Option[string]
        force, overwrite, cleanup: Option[bool]
        code: Option[int]

type
    MessageResp* = object
        cmd*, version*, error*, sep*: string
        content*, command*: Option[string]

        files, capabilities: seq[string]

        isDir: bool
        code: Option[int]

func toJson(m: MessageResp): JsonNode =
    result = newJObject()
    for name, value in m.fieldPairs:
        when name in ["cmd", "version", "error", "sep"]: # strings
            if value.len > 0:
                result[name] = value.newJString
        elif name in ["content", "command", "code"]: # options
            if value.isSome:
                result[name] = %value.get
        elif name == "isDir":
            if m.sep.len > 0:
                result["isDir"] = value.newJBool
        elif name == "files":
            if value.len > 0:
                var files = newJArray()
                for file in value:
                    files.add file.newJString
                result[name] = files
        elif name == "capabilities":
            if value.len > 0:
                result[name] = %value
        else:
            {.error: "Unhandled MessageResp field: " & name.}

# Vastly simpler than the Python version
# Let's let users check if that matters : )
func sanitiseFilename(fn: string): string =
    for c in toLowerAscii(fn):
        if isAlphaNumeric(c) or c == '.':
            result.add c

    result = result.replace("..", ".")

proc findUserConfigFile(): string =
    # The standard config dir is the same as stdlib, except on Windows where we also allow `XDG_CONFIG_HOME` when set.
    let standardConfigDir =
        when not defined(windows):
            getConfigDir()
        else:
            getEnv("XDG_CONFIG_HOME", getConfigDir())

    let candidateFiles =
        [
            standardConfigDir / "tridactyl" / "tridactylrc",
            getHomeDir() / ".config" / "tridactyl" / "tridactylrc",
            getHomeDir() / "_config" / "tridactyl" / "tridactylrc",
            getHomeDir() / ".tridactylrc",
            getHomeDir() / "_tridactylrc",
        ]

    for path in candidateFiles:
        if fileExists(path):
            return path

proc expandVars(path: string): string =
    result = path
    when defined(posix):
        if "$" notin result:
            return

        var
            name, value, tail: string
            (first, last) = (0, 0)
        while true:
            var bounds_slices = findAllBounds(result, re"\$(\w+|\{[^}]*\})", first)
            if bounds_slices.len == 0:
                break
            (first, last) = (bounds_slices[0].a, bounds_slices[0].b)
            if first < 0 or last < first:
                break
            name = result[first + 1 .. last]
            if name.startsWith('{') and name.endsWith('}'):
                name = name[1 .. ^2]
            if existsEnv(name):
                value = getEnv(name)
            else:
                first = last
                continue
            tail = result[last + 1 .. ^1]
            result = result[0 .. first - 1] & value
            first = len(result)
            result = result & tail

proc handleMessage(msg: MessageRecv): MessageResp =
    let cmd = msg.cmd.get()
    result.cmd = cmd

    case cmd:
        of "version":
            result.version = VERSION
            result.capabilities = @[CONTROL_CAPABILITY]
            result.code = some 0

        of "getconfig":
            try:
                let maybePath = findUserConfigFile()
                if maybePath.len == 0:
                    result.code = some(1)
                else:
                    result.content = some(readFile(maybePath))
                    result.code = some(0)
            except IOError:
                result.code = some(2)

        of "getconfigpath":
            let config = findUserConfigFile()
            if config.len == 0:
                result.code = some(1)
            else:
                result.content = some config
                result.code = some(0)

        of "run":
            when defined(windows):
                let command = "cmd /c " & msg.command.get()
            else:
                let command = msg.command.get()

            result.command = some command
            let process = startProcess(command, options = {poEvalCommand,
                    poStdErrToStdOut})
            if msg.content.isSome:
                process.inputStream.write(msg.content.get())
                process.inputStream.close()

            var content = ""
            for line in process.outputStream.lines:
                content.add(line)
                content.add('\n')
            result.content = some content
            result.code = some waitForExit(process)
            close(process)

        of "run_async":
            when defined(windows):
                let command = "cmd /c " & msg.command.get()
                createOrphanProcess(command)
            else:
                let command = msg.command.get()
                discard startProcess(command, options = {poEvalCommand})

            result.command = some command

        of "eval":
            # do we actually want to implement this?
            # we'd have to start up Python
            # with whatever stuff is usually used imported

            # should probably defenestrate it instead
            write(stderr, "TODO: NOT IMPLEMENTED\n")

        of "read":
            var f: File
            if open(f, expandTilde(expandVars(msg.file.get()))):
                result.content = some(readAll(f))
                result.code = some(0)
                close(f)
            else:
                result.code = some(2)
                result.content = some("")

        of "mkdir":
            try:
                createDir(expandTilde(expandVars((msg.dir.get()))))
                result.content = some("")
                result.code = some(0)
            except OSError:
                result.code = some(2)

        of "move":
            let src = expandTilde(expandVars(msg.`from`.get()))
            let dst = expandTilde(expandVars(msg.to.get()))
            let canMove = msg.overwrite.get(false) or not(fileExists(dst) or
                    fileExists(joinPath(dst, extractFilename(src))))

            if canMove:
                try:
                    # On OSX, we use POSIX `mv` to bypass restrictions
                    # introduced in Big Sur on moving files downloaded
                    # from the internet
                    when defined(macosx):
                        let mvCmd = quoteShellCommand([
                            "mv",
                            "-f",
                            src, dst
                            ])
                        result.code = some execCmd(mvCmd)
                        if result.code != some 0:
                            raise newException(OSError, "\"" & mvCmd & "\" failed on MacOS ...")
                    else:
                        if dirExists dst:
                            moveFile(src, dst / extractFilename(src))
                        else:
                            moveFile(src, dst)
                        result.code = some(0)
                except OSError:
                    result.code = some(2)
            else:
                result.code = some(1)

            if msg.cleanup.get(false):
                when defined(macosx):
                    let rmCmd = quoteShellCommand([
                            "rm",
                            "-f",
                            src
                        ])
                    discard execCmdEx(rmCmd, options = {poEvalCommand,
                            poStdErrToStdOut})
                else:
                    removeFile(src)

        of "write":
            try:
                var f: File
                discard open(f, expandTilde(expandVars(msg.file.get())), fmWrite)
                var msgContent = msg.content.get()
                let expr = re"^data:((.*?)(;charset=.*?)?)(;base64)?,"
                if match(msgContent, expr):
                    msgContent = decode(replace(msgContent, expr, ""))
                write(f, msgContent)
                result.code = some(0)
                close(f)
            except IOError:
                result.code = some(2)

        of "writerc":
            let path = expandTilde(expandVars(msg.file.get()))
            if not fileExists(path) or msg.force.get(false):
                try:
                    var f: File
                    discard open(f, path, fmWrite)
                    write(f, msg.content.get())
                    result.code = some(0)
                    close(f)
                except IOError:
                    result.code = some(2)
            else:
                result.code = some(1)

        of "temp":
            try:
                let prefix = "tmp_" & sanitiseFilename(msg.prefix.get("")) & "_"
                var (f, filepath) = mkstemp(prefix, ".txt", "", fmWrite)
                write(f, msg.content.get())
                result.code = some(0)
                result.content = some(filepath)
                close(f)
            except IOError:
                result.code = some(2)

        of "env":
            result.content = some(getEnv(msg.`var`.get()))

        of "list_dir":
            var path = expandTilde(msg.path.get())
            result.isDir = dirExists(path)
            if not result.isDir:
                path = parentDir(path) # returns "." for parent of bare file

            for _, dir in walkDir(path):
                result.files.add dir.lastPathPart

            result.sep = $DirSep

        of "win_firefox_restart":
            #[
                Because of the way Firefox calls the native messenger, making
                that same messenger restart Firefox is no easy feat: when
                Firefox calls the messenger, it tells Windows to create a Job
                for that process and all its children. When Firefox exits, it
                tells Windows to terminate all processes belonging to that Job,
                which would make it impossible for the messenger to re-invoke
                Firefox, since it'd have been killed by that point.

                We circumvent this by having the "parent" messenger start a
                process that is specifically outside of any Job and will thus
                be unaffected by Firefox exiting. This "orphan" is passed
                the user's profile directory, the path to firefox.exe and
                the process ID of its grandparent, Firefox. It then waits for
                Firefox to exit and afterwards calls it using the binary path
                and the profile directory it was given.
            ]#
            when defined windows:
                if msg.profiledir.isNone or msg.browsercmd.isNone:
                    result.cmd = "error"
                    result.error = "win_firefox_restart: profile or browser executable name not specified"
                else:
                    try:
                        let orphanCommandLine = getOrphanMessengerCommand(
                          msg.profiledir.get(),
                          msg.browsercmd.get(),
                        )
                        createOrphanProcess(orphanCommandLine)
                        result.code = some(0)
                        result.content = some("Restarting...")
                    except OSError as error:
                        result.cmd = "error"
                        result.error = "OSError " & $error.errorCode & ": " & error.msg
                    except:
                        result.cmd = "error"
                        result.error = getCurrentExceptionMsg()
            else:
                result.cmd = "error"
                result.error = "win_firefox_restart is only available on Windows"

        of "ppid":
            when defined posix:
                result.content = some($getppid())
            elif defined windows:
                result.content = some($getppidWindows())
            else: 
                result.cmd = "error"
                result.error = "ppid is not available on this OS"

        else:
            result.cmd = "error"
            result.error = "Unhandled message"
            write(stderr, "Unhandled message: " & $msg & "\n")

func errorMessage(message: string): JsonNode =
    var response: MessageResp
    response.cmd = "error"
    response.error = message
    response.toJson

proc handshakeResponse(message: JsonNode): JsonNode =
    result = %*{
        "type": "control.handshake",
        "protocol": CONTROL_PROTOCOL,
        "enabled": false
    }
    if not message.hasKey("protocol") or message["protocol"].kind != JInt or
      message["protocol"].getBiggestInt != CONTROL_PROTOCOL:
        result["error"] = %"unsupported control protocol"
        return
    if not message.hasKey("enable") or message["enable"].kind != JBool:
        result["error"] = %"handshake requires a boolean enable field"
        return

    if not message["enable"].getBool:
        stopControl()
        return

    let started = startControl()
    if started.ok:
        result["enabled"] = %true
        result["instance"] = %started.instance
    else:
        result["error"] = %started.error

proc relayControlResponse(message: JsonNode) =
    if not message.hasKey("id") or message["id"].kind != JString:
        stderr.writeLine("Ignoring a control response without an ID")
        return
    let id = message["id"].getStr
    var response = %*{"protocol": CONTROL_PROTOCOL, "ok": false}
    if not message.hasKey("protocol") or message["protocol"].kind != JInt or
      message["protocol"].getBiggestInt != CONTROL_PROTOCOL or
      not message.hasKey("ok") or message["ok"].kind != JBool:
        response["error"] = %"invalid extension response"
    elif message["ok"].getBool:
        response["ok"] = %true
        if message.hasKey("result"):
            response["result"] = message["result"]
    elif message.hasKey("error") and message["error"].kind == JString:
        response["error"] = message["error"]
    else:
        response["error"] = %"extension request failed"
    discard deliverControlResponse(id, $response)

proc runRequestMode(params: seq[string]): int =
    var
        command = ""
        instance = ""
        index = 1
    while index < params.len:
        if params[index] == "--instance":
            if index + 1 >= params.len or instance.len > 0:
                stderr.writeLine("Usage: native_main --request COMMAND [--instance ID]")
                return 2
            instance = params[index + 1]
            index += 2
        elif command.len == 0:
            command = params[index]
            inc index
        else:
            stderr.writeLine("Usage: native_main --request COMMAND [--instance ID]")
            return 2
    if command.len == 0:
        stderr.writeLine("Usage: native_main --request COMMAND [--instance ID]")
        return 2
    runCli(command, instance)

proc printUsage() =
    stdout.writeLine("Usage: native_main --request COMMAND [--instance ID]")
    stdout.writeLine("       native_main --version")

let params = commandLineParams()
when defined windows:
    # Usage: native_main.exe restart <Firefox PID> <profile dir> <browser exe name>
    # This should only invoked by the native messenger itself to perform
    # :restart on Windows. See also windows_restart.getOrphanMessengerCommand.
    if params.len == 4 and params[0] == "restart":
        orphanMain(browserPid = params[1].parseInt(),
          profiledir = params[2], browserExePath = params[3])
        quit()

if params.len > 0 and params[0] == "--request":
    quit(runRequestMode(params))
if params == @["--help"]:
    printUsage()
    quit(0)
if params == @["--version"]:
    stdout.writeLine(VERSION)
    quit(0)

initControlBridge()
let strm = newFileStream(stdin)

while true:
    let frame = readNativeFrame(strm)
    if frame.kind == nfkEof:
        break
    if frame.kind == nfkInvalid:
        stderr.writeLine(frame.error)
        break

    var message: JsonNode
    try:
        message = parseJson(frame.payload)
    except JsonParsingError:
        stderr.writeLine("Malformed native JSON message")
        if not writeNative($errorMessage("Malformed native message")):
            break
        continue

    if message.kind != JObject:
        if not writeNative($errorMessage("Malformed native message")):
            break
    elif message.hasKey("cmd"):
        try:
            if not writeNative($handleMessage(message.to(MessageRecv)).toJson):
                break
        except Exception:
            stderr.writeLine("Malformed legacy native message")
            if not writeNative($errorMessage("Malformed native message")):
                break
    elif message.hasKey("type") and message["type"].kind == JString and
      message["type"].getStr == "control.handshake":
        if not writeNative($handshakeResponse(message)):
            break
    elif message.hasKey("type") and message["type"].kind == JString and
      message["type"].getStr == "control.response":
        relayControlResponse(message)
    else:
        if not writeNative($errorMessage("Unhandled message")):
            break

stopControl(extensionDisconnected = true)
strm.close()
