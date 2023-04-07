import json
import options
import osproc
import streams
import os
import strutils
import posix
import regex
import base64

# Third party stuff
import tempfile

# Platform-specific stuff
when defined(windows):
    import windows_helpers

const VERSION = "0.3.7"

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

        files: seq[string]

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
        else:
            {.error: "Unhandled MessageResp field: " & name.}

# Vastly simpler than the Python version
# Let's let users check if that matters : )
func sanitiseFilename(fn: string): string =
    for c in toLowerAscii(fn):
        if isAlphaNumeric(c) or c == '.':
            result.add c

    result = result.replace("..", ".")

proc getMessage(strm: Stream): MessageRecv =
    try:
        var length: int32
        read(strm, length)
        if length == 0:
            close(strm)
            quit(0)

        let
            message = readStr(strm, length)
            rawJson = parseJson(message)

        return rawJson.to(MessageRecv)

    except IOError:
        close(strm)
        quit(0)


proc findUserConfigFile(): string =
    let candidateFiles =
        when not defined(windows):
            [
                getConfigDir() / "tridactyl" / "tridactylrc",
                getHomeDir() / ".config" / "tridactyl" / "tridactylrc",
                getHomeDir() / "_config" / "tridactyl" / "tridactylrc",
                getHomeDir() / ".tridactylrc",
                getHomeDir() / "_tridactylrc",
            ]
        else:
            [
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

when defined windows:
    let params = commandLineParams()
    # Usage: native_main.exe restart <Firefox PID> <profile dir> <browser exe name>
    # This should only invoked by the native messenger itself to perform
    # :restart on Windows. See also windows_restart.getOrphanMessengerCommand.
    if params.len == 4 and params[0] == "restart":
        orphanMain(browserPid = params[1].parseInt(),
          profiledir = params[2], browserExePath = params[3])
        quit()

let strm = newFileStream(stdin)

while true:
    let
        message = $handleMessage(getMessage(strm)).toJson
        lengthPayload = cast[array[4, byte]](message.len.uint32)
    discard writeBytes(stdout, lengthPayload, 0, lengthPayload.len)
    write(stdout, message)
    flushFile(stdout)
