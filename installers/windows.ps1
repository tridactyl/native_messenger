<#
.Parameter Uninstall
    Whether to uninstall an existing native messenger installation.
.Parameter InstallDirectory
    The directory in which the native messenger should be installed. Defaults
    to "$env:USERPROFILE\.tridactyl".
.Parameter Tag
    The Tridactyl version to which the corresponding version of the native
    messenger should be installed. Tridactyl versions lower than 1.21.0 are not
    supported.
#>
Param (
    [switch]$Uninstall = $false,
    [string]$InstallDirectory = "$env:USERPROFILE\.tridactyl",
    [string]$Tag = "master"
)

function Install-NativeMessenger {
    # Pre-5.1 versions of Powershell might not have a TLS version that GitHub
    # supports enabled by default.
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $MessengerVersion = (Invoke-WebRequest `
            "https://raw.githubusercontent.com/tridactyl/tridactyl/$Tag/native/current_native_version").`
        Content.Trim()
    Write-Output "Installing native messenger version $MessengerVersion in $InstallDirectory"

    Write-Output "Entering $InstallDirectory"
    New-Item -ItemType Directory $InstallDirectory -Force > $null
    Push-Location $InstallDirectory

    Write-Output "Downloading native messenger"
    Invoke-WebRequest `
        "https://github.com/tridactyl/native_messenger/releases/download/$MessengerVersion/native_main-Windows" `
        -OutFile "native_main.exe"

    Write-Output "Downloading manifest"
    (Invoke-WebRequest `
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
    $MessengerDirectory = (Get-ItemProperty `
            -Path "HKCU:\SOFTWARE\Mozilla\NativeMessagingHosts\tridactyl")."(default)" |
        Get-Item | Select-Object -ExpandProperty Directory

    $yes = New-Object System.Management.Automation.Host.ChoiceDescription `
        "&Yes", "Uninstall the native messenger."
    $no = New-Object System.Management.Automation.Host.ChoiceDescription `
        "&No", "Do nothing."
    if ($Host.UI.PromptForChoice("Uninstall native messenger", `
                "Are you sure you want to uninstall the native messenger from $MessengerDirectory`?",
            @($yes, $no), 1) -eq 1) {
        Write-Output "Uninstallation cancelled"
        exit
    }

    Write-Output "Unregistering messenger"
    Remove-Item -Path "HKCU:\SOFTWARE\Mozilla\NativeMessagingHosts\tridactyl" `
        -Force -Recurse

    Write-Output "Entering $MessengerDirectory"
    Push-Location $MessengerDirectory

    Write-Output "Deleting messenger, manifest, and installer"
    # We don't care about errors finding the files - that just means we don't
    # have to remove them. We do care about errors deleting them, because that
    # might mean manual intervention is necessary to completely remove the
    # native messenger.
    Get-ChildItem "native_main.exe", "tridactyl.json", "installer.ps1" -ErrorAction SilentlyContinue | Remove-Item

    Write-Output "Exiting $MessengerDirectory"
    Pop-Location
    Write-Output "Done"
}

if ($Uninstall) {
    Uninstall-NativeMessenger
} else {
    Install-NativeMessenger
}
