import os
import json
import posix
import times
import osproc
import options
import streams
import strutils

# Third party stuff
import struct
import tempfile

var DEBUG = false
const NATIVE_MAIN_LOG = "native_main.log"
const VERSION = "0.3.0"

# Platform-specific stuff
when defined(windows):
    import windows_restart

type
    MessageRecv* = object
        cmd*, version*, content*, error*, command*, `var`*, file*, dir*, to*,
            `from`*, prefix*, path*, profiledir*, browsercmd*: Option[string]
        force: Option[bool]
        code: Option[int]
        overwrite: Option[bool]
        cleanup: Option[bool]
type
    MessageResp* = object
        cmd*, version*, content*, error*, command*, sep*: Option[string]

        # This should be a JArray but I can't work out how to specify that
        files: Option[JsonNode]

        isDir: Option[bool]
        code: Option[int]

proc writeLog(msg: string) =
    if DEBUG:
        let now = times.now()
        writeFile(NATIVE_MAIN_LOG, $now & " :: " & msg)

# Vastly simpler than the Python version
# Let's let users check if that matters : )
proc sanitiseFilename(fn: string): string =
    var ans = ""
    for c in toLowerAscii(fn):
        if isAlphanumeric(c) or c == '.':
            add(ans,c)

    return replace(ans,"..",".")

proc getMessage(strm: Stream): MessageRecv =
    try:
        var length: int32
        read(strm,length)
        if length == 0:
            close(strm)
            quit(0)

        let message = readStr(strm, length)
        var raw_json = parseJson(message)

        writeLog(">> raw_json == " & $raw_json & "\n")

        return to(raw_json,MessageRecv)

    except IOError:
        close(strm)
        quit(0)


proc findUserConfigFile(): Option[string] =
    let config_dir = getenv("XDG_CONFIG_HOME", expandTilde("~/.config"))
    let candidate_files = [
        config_dir / "tridactyl" / "tridactylrc",
        getHomeDir() / ".tridactylrc",
        getHomeDir() / "_config", "tridactyl" / "tridactylrc",
        getHomeDir() / "_tridactylrc",
    ]

    var config_path = none(string)

    for path in candidate_files:
        if fileExists(path):
            config_path = some(path)
            break

    return config_path

proc handleMessage(msg: MessageRecv): string =
    let cmd = msg.cmd.get()
    var reply: MessageResp
    reply.cmd = some cmd

    case cmd:
        of "version":
            reply.version = some(VERSION)
            reply.code = some 0

        of "getconfig":
            try:
                let maybePath = findUserConfigFile()
                if not isSome(maybePath):
                    reply.code = some(1)
                else:
                    var f: File
                    discard open(f, maybePath.get())
                    reply.content = some(readAll(f))
                    reply.code = some(0)
                    close(f)
            except IOError:
                reply.code = some(2)

        of "getconfigpath":
            reply.content = findUserConfigFile()
            reply.code = some(0)
            if not isSome(reply.content):
                reply.code = some(1)

        of "run":
            when defined(windows):
                let command = "cmd /c " & msg.command.get()
            else:
                let command = msg.command.get()

            reply.command = some command
            let process = startProcess(command, options={poEvalCommand, poStdErrToStdOut})

            # Nicked from https://github.com/nim-lang/Nim/blob/1d8b7aa07ca9989b80dd758d66c7f4ba7dc533f7/lib/pure/osproc.nim#L507
            # Not 100% sure we can't just use readAll
            let outp = outputStream(process)
            var content = ""
            var line = newStringOfCap(120)
            while true:
                if readLine(outp, line):
                  content.string.add(line.string)
                  content.string.add("\n")
                elif not running(process): break
            reply.content = some content
            reply.code = some waitForExit(process)
            close(process)

        of "eval":
            # do we actually want to implement this?
            # we'd have to start up Python
            # with whatever stuff is usually used imported

            # should probably defenestrate it instead
            write(stderr, "TODO: NOT IMPLEMENTED\n")

        of "read":
            var f: File
            if open(f, expandTilde(msg.file.get())):
                reply.content = some(readAll(f))
                reply.code = some(0)
                close(f)
            else:
                reply.content = none(string)
                reply.code = some(2)

        of "mkdir":
            try:
                createDir(expandTilde(msg.dir.get()))
                reply.content = some("")
                reply.code = some(0)
            except OSError:
                reply.code = some(2)

        of "move":
            var src = expandTilde(msg.`from`.get())
            writeLog(">> src == " & $src & "\n")

            var dst = expandTilde(msg.to.get())
            writeLog(">> dst == " & $dst & "\n")

            let overwrite = msg.overwrite.get(false)
            let cleanup = msg.cleanup.get(false)

            var dstFileExists = false
            if overwrite == false:
                if fileExists(dst) or fileExists(joinPath(dst, extractFilename(src))):
                    reply.code = some(1)
                    dstFileExists = true

            if dstFileExists == false or overwrite == true:
                try:
                    # On OSX, we use POSIX `mv` to bypass restrictions
                    # introduced in Big Sur on moving files downloaded
                    # from the internet
                    when defined(macosx):
                        var mvCmd = quoteShellCommand([
                                "mv",
                                "-f",
                                src,
                                dst
                            ])
                        writeLog(">> mvCmd == " & $mvCmd & "\n")
                        let mvStatus = execCmdEx(mvCmd, options={poEvalCommand, poStdErrToStdOut})
                        writeLog(">> mvStatus == " & $mvStatus & "\n")

                        if mvStatus.exitCode != 0:
                            raise newException(OSError, "\"" & mvCmd & "\" failed on MacOS ...")
                        else:
                            reply.code = some(0)
                    else:
                        moveFile(src, dst)
                        reply.code = some(0)
                except OSError:
                    reply.code = some(2)

            if cleanup:
                when defined(macosx):
                    let rmCmd = quoteShellCommand([
                            "rm",
                            "-f",
                            src
                        ])
                    writeLog(">> rmCmd == " & $rmCmd & "\n")
                    discard execCmdEx(rmCmd, options={poEvalCommand, poStdErrToStdOut})
                else:
                    discard removeFile(src)

            writeLog(">> move() reply.code == " & $reply.code & "\n")

        of "write":
            try:
                var f: File
                discard open(f, expandTilde(msg.file.get()), fmWrite)
                write(f, msg.content.get())
                reply.code = some(0)
                close(f)
            except IOError:
                reply.code = some(2)

        of "writerc":
            let path = expandTilde(msg.file.get())
            if not fileExists(path) or msg.force.get(false):
                try:
                    var f: File
                    discard open(f, path, fmWrite)
                    write(f, msg.content.get())
                    reply.code = some(0)
                    close(f)
                except IOError:
                    reply.code = some(2)
            else:
                reply.code = some 1

        of "temp":
            try:
                let prefix = "tmp_" & sanitiseFilename(msg.prefix.get("")) & "_"
                var (f, filepath) = mkstemp(prefix, ".txt", "", fmWrite)
                write(f, msg.content.get())
                reply.code = some(0)
                reply.content = some(filepath)
                close(f)
            except IOError:
                reply.code = some(2)

        of "env":
            reply.content = some(getEnv(msg.`var`.get()))

        of "list_dir":
            var path = expandTilde(msg.path.get())
            reply.isDir = some dirExists(path)
            if not reply.isDir.get(false):
                path = parentDir(path) # returns "." for parent of bare file
            let files = newJArray()

            # Surely there's a better way of doing this
            for (kind, dir) in walkDir(path):
                add(files, newJString(lastPathPart(dir)))

            reply.files = some files
            reply.sep = some $DirSep

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
                if not isSome(msg.profiledir) or not isSome(msg.browsercmd):
                    reply.cmd = some("error")
                    reply.error = some("win_firefox_restart: profile or browser executable name not specified")
                else:
                    try:
                        let orphanCommandLine = getOrphanMessengerCommand(
                            msg.profiledir.get(),
                            msg.browsercmd.get(),
                        )
                        createOrphanProcess(orphanCommandLine)
                        reply.code = some(0)
                        reply.content = some("Restarting...")
                    except OSError as error:
                        reply.cmd = some("error")
                        reply.error = some("OSError " & $ error.errorCode & ": " & error.msg)
                    except:
                        reply.cmd = some("error")
                        reply.error = some(getCurrentExceptionMsg())
            else:
                reply.cmd = some("error")
                reply.error = some("win_firefox_restart is only available on Windows")

        of "ppid":
            when defined posix:
                reply.content = some($getppid())
            else:
                reply.cmd = some("error")
                reply.error = some("ppid is not available on this OS")

        else:
            reply.cmd = some("error")
            reply.error = some("Unhandled message")
            write(stderr, "Unhandled message: " & $ msg & "\n")

    return $ %* reply # $ converts to string, %* converts to JSON

if os.getEnv("TRIDACTYL_DEBUG") == "1":
    DEBUG = true

when defined windows:
    let params = commandLineParams()
    # Usage: native_main.exe restart <Firefox PID> <profile dir>
    # <browser exe name> This should only invoked by the native
    # messenger itself to perform :restart on Windows. See also
    # windows_restart.getOrphanMessengerCommand.
    if len(params) == 4 and params[0] == "restart":
        orphanMain(browserPid = params[1].parseInt(),
            profiledir = params[2], browserExePath = params[3])
        quit()

while true:
    let strm = newFileStream(stdin)
    let message = handleMessage(getMessage(strm))
    let message_length = pack("@I", message.len)

    writeLog(">> message ==" & message & "\n")
    writeLog(">> message_length ==" & $message.len & "(" & $message_length & ")\n")

    write(stdout, message_length)
    write(stdout, message)
    flushFile(stdout)
