## Procedures necessary for implementing :restart on Windows

import winlean, os, osproc

template doWhile(a: bool, b:untyped): untyped =
    b
    while a:
        b

type
    ## See https://docs.microsoft.com/en-us/windows/win32/api/tlhelp32/ns-tlhelp32-processentry32
    PROCESSENTRY32 = object
        dwSize: DWORD
        cntUsage: DWORD
        th32ProcessID: DWORD
        th32DefaultHeapID: ULONG_PTR
        th32ModuleID: DWORD
        cntThreads: DWORD
        th32ParentProcessID: DWORD
        pcPriClassBase: LONG
        dwFlags: DWORD
        # winlean does not include the CHAR type, but Windows.h just typedefs CHAR to char anyway.
        # Win32 API type names are otherwise used for consistency with the documentation.
        szExeFile: array[MAX_PATH, cchar]

## See https://docs.microsoft.com/en-us/windows/win32/api/tlhelp32/nf-tlhelp32-createtoolhelp32snapshot
proc createToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD): Handle
    {.stdcall, dynlib: "kernel32", importc: "CreateToolhelp32Snapshot".}

## See https://docs.microsoft.com/en-us/windows/win32/api/tlhelp32/nf-tlhelp32-process32first
proc process32First(hSnapshot: Handle, lppe: var PROCESSENTRY32): bool
    {.stdcall, dynlib: "kernel32", importc: "Process32First".}

## See https://docs.microsoft.com/en-us/windows/win32/api/tlhelp32/nf-tlhelp32-process32next
proc process32Next(hSnapshot: Handle, lppe: var PROCESSENTRY32): bool
    {.stdcall, dynlib: "kernel32", importc: "Process32Next".}

## Unlike POSIX getppid, can be passed an arbitrary PID.
proc getppidWindows*(pid = getCurrentProcessId().DWORD): DWORD =
    # dwFlags=2 causes the snapshot to include all currently running processes
    # th32ProcessID=0 refers to the calling process
    let handle = createToolhelp32Snapshot(dwFlags = 2, th32ProcessID = 0)
    var processEntry: PROCESSENTRY32
    processEntry.dwSize = sizeof(PROCESSENTRY32).DWORD

    if process32First(handle, processEntry):
        doWhile process32Next(handle, processEntry):
            if processEntry.th32ProcessID == pid:
                discard closeHandle handle
                return processEntry.th32ParentProcessID

    raise newException(OSError, "Could not determine parent process id")

## Invoke the native messenger again with special arguments and outside the
## Job Firefox starts it in. This is necessary because Firefox kills every
## process in the messenger's job when it itself exits, but to be able to
## restart Firefox we need a process which survives that.
proc createOrphanProcess*(commandLine: string) =
    var
        startupInfo: STARTUPINFO
        processInformation: PROCESS_INFORMATION
    let success = createProcessW(
        lpCommandLine = commandLine.newWideCString(),
        # dwCreationFlags = CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW
        # See https://docs.microsoft.com/en-gb/windows/win32/procthread/process-creation-flags#CREATE_BREAKAWAY_FROM_JOB
        dwCreationFlags = 0x01000000 or 0x08000000,

        # We don't care about the rest of the arguments, but we are required to
        # specify them.
        lpStartupInfo = startupInfo,
        lpProcessInformation = processInformation,
        lpApplicationName = nil.newWideCString(),
        lpProcessAttributes = nil,
        lpThreadAttributes = nil,
        bInheritHandles = false.WINBOOL,
        lpEnvironment = nil.newWideCString(),
        lpCurrentDirectory = nil.newWideCString(),
    ).bool

    if not success:
        raise newException(
            OSError,
            "Could not create orphaned messenger process"
        )

proc getOrphanMessengerCommand*(profiledir, browserName: string): string =
    let browserExePath = findExe(browserName, followSymlinks = false)
    if browserExePath == "":
        raise newException(CatchableError, "Browser executable not found")
    return quoteShellCommand([
        getAppFilename(),
        "restart",
        $ getppidWindows(),
        profiledir,
        browserExePath,
    ])

proc waitForProcess*(pid: int) =
    let processHandle = openProcess(
        dwDesiredAccess = SYNCHRONIZE.DWORD,
        bInheritHandle = false.WINBOOL,
        dwProcessId = pid.DWORD
    )
    discard waitForSingleObject(
        hHandle = processHandle,
        dwMilliseconds = INFINITE
    )

## The main function for the orphaned native messenger.
## Waits for Firefox instance with PID ``browserPid`` to exit, then restarts it
## with binary ``browserExePath`` and profile ``profiledir``.
proc orphanMain*(browserPid: int, profiledir, browserExePath: string) =
    waitForProcess(browserPid)

    let browserCommand = quoteShellCommand([
        browserExePath,
        "-profile",
        profiledir,
    ])
    discard startProcess(browserCommand, options = {poEvalCommand})
