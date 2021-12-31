<#
.Parameter Uninstall
    Whether to uninstall an existing native messenger installation.
.Parameter Tag
    The Tridactyl version to which the corresponding version of the native
    messenger should be installed. Tridactyl versions lower than 1.21.0 are not
    supported.
.Parameter InstallDirectory
    The directory in which the native messenger should be installed. Defaults
    to "$env:USERPROFILE\.tridactyl". This parameter is not honoured when an
    existing installation is found.
#>
Param (
    [switch]$Uninstall = $false,
    [string]$Tag = "master",
    [string]$InstallDirectory = "$env:USERPROFILE\.tridactyl"
)

function Get-ExistingManifest {
    if (Test-Path "HKCU:\SOFTWARE\Mozilla\NativeMessagingHosts\tridactyl") {
        $ManifestLocation = (Get-ItemProperty "HKCU:\SOFTWARE\Mozilla\NativeMessagingHosts\tridactyl")."(default)"
        if ($ManifestLocation -and (Test-Path $ManifestLocation)) {
            return Get-Item $ManifestLocation
        }
    }
    return $null
}

function Install-NativeMessenger {
    if ($ExistingManifest = Get-ExistingManifest) {
        $InstallDirectory = $ExistingManifest.Directory
    }

    # Pre-5.1 versions of Powershell might not have a TLS version that GitHub
    # supports enabled by default.
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $MessengerVersion = (Invoke-WebRequest -UseBasicParsing `
            "https://raw.githubusercontent.com/tridactyl/tridactyl/$Tag/native/current_native_version").`
        Content.Trim()
    Write-Output "Installing native messenger version $MessengerVersion in $InstallDirectory"

    Write-Output "Entering $InstallDirectory"
    New-Item -ItemType Directory $InstallDirectory -Force > $null
    Push-Location $InstallDirectory

    Write-Output "Downloading native messenger"
    $MessengerRequest = Invoke-WebRequest -UseBasicParsing `
        "https://github.com/tridactyl/native_messenger/releases/download/$MessengerVersion/native_main-Windows"
    if (-not (Test-Path "native_main.exe")) {
        New-Item -ItemType File "native_main.exe"
    }
    for ($i = 0; $i -le 4; $i++) {
        try {
            [System.IO.File]::WriteAllBytes($(Resolve-Path "native_main.exe"), $MessengerRequest.Content)
            break
        } catch {
            if ($i -eq 4) {
                Write-Error @"
Native messenger binary could not be replaced. If it is currently running, stop
the process and try again.
"@
                Pop-Location
                exit 1
            }
            Start-Sleep 1
        }
    }

    Write-Output "Downloading manifest"
    (Invoke-WebRequest -UseBasicParsing `
            "https://raw.githubusercontent.com/tridactyl/native_messenger/$MessengerVersion/tridactyl.json").`
        Content.Replace("REPLACE_ME_WITH_SED", "native_main.exe") |
        Set-Content -Path "tridactyl.json"

    Write-Output "Registering native messenger"
    New-Item -ItemType Directory `
        "HKCU:\SOFTWARE\Mozilla\NativeMessagingHosts\tridactyl" `
        -Force > $null
    New-ItemProperty -Path "HKCU:\SOFTWARE\Mozilla\NativeMessagingHosts\tridactyl" `
        -Name "(default)" -PropertyType String `
        -Value $((Get-Item "tridactyl.json").FullName) `
        -Force > $null

    Copy-Item $PSCommandPath "installer.ps1"

    Write-Output "Exiting $InstallDirectory"
    Pop-Location
    Write-Output "Done"
    Write-Output @"
The installer for the native messenger has been copied to $InstallDirectory.
To uninstall the native messenger, navigate to that directory in Powershell
and run ".\installer.ps1 -Uninstall".
"@
    exit
}

function Uninstall-NativeMessenger {
    if (-not ($ExistingManifest = Get-ExistingManifest)) {
        Write-Error "Native messenger not found, cannot uninstall!"
        exit 1
    } else {
        $InstallDirectory = $ExistingManifest.Directory
    }

    $yes = New-Object System.Management.Automation.Host.ChoiceDescription `
        "&Yes", "Uninstall the native messenger."
    $no = New-Object System.Management.Automation.Host.ChoiceDescription `
        "&No", "Do nothing."
    if ($Host.UI.PromptForChoice("Uninstall native messenger", `
                "Are you sure you want to uninstall the native messenger from $InstallDirectory`?",
            @($yes, $no), 1) -eq 1) {
        Write-Output "Uninstallation cancelled"
        exit
    }

    Write-Output "Unregistering messenger"
    Remove-Item -Path "HKCU:\SOFTWARE\Mozilla\NativeMessagingHosts\tridactyl" `
        -Force -Recurse

    Write-Output "Entering $InstallDirectory"
    Push-Location $InstallDirectory

    Write-Output "Deleting messenger, manifest, and installer"
    # We don't care about errors finding the files - that just means we don't
    # have to remove them. We do care about errors deleting them, because that
    # might mean manual intervention is necessary to completely remove the
    # native messenger.
    Get-ChildItem "native_main.exe", "tridactyl.json", "installer.ps1" -ErrorAction SilentlyContinue | Remove-Item

    Write-Output "Exiting $InstallDirectory"
    Pop-Location
    Write-Output "Done"
}

if ($Uninstall) {
    Uninstall-NativeMessenger
} else {
    Install-NativeMessenger
}
