#!/usr/bin/env sh

echoerr() {
    red="\\033[31m"
    normal="\\e[0m"
    printf "%b\n" "$red$*$normal" >&2
}

sedEscape() {
    printf "%s" "$@" | sed 's/[&/\]/\\&/g'
}

# To install, curl -fsSl 'url to this script' | sh
# Or run "./installers/install.sh local" in the repository of the
# native messanger.

run() {
    set -e

    HOME="${HOME:-$(echo ~)}"

    # Decide where to put the manifest based on OS
    # Get OSTYPE from bash if it's installed. If it's not, then this will
    # default to the Linux location as OSTYPE will be empty
    OSTYPE="$(command -v bash >/dev/null && bash -c 'echo $OSTYPE')"
    case "$OSTYPE" in
        linux-gnu|linux-musl|linux|freebsd*)
            manifest_home="$HOME/.mozilla/native-messaging-hosts/"
            binary_suffix="Linux"
            ;;
        linux-gnueabihf)
            manifest_home="$HOME/.mozilla/native-messaging-hosts/"
            binary_suffix="armhf-Linux"
            ;;
        darwin*)
            manifest_home="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts/"
            binary_suffix="macOS"
            ;;
        *)
            # Fallback to default Linux location for unknown OSTYPE
            # TODO: fall back to old Python messenger
            manifest_home="$HOME/.mozilla/native-messaging-hosts/"
            binary_suffix="Linux"
            ;;
    esac

    if [ "$1" = "local" ] ; then
        manifest_loc="file://"$(pwd)"/tridactyl.json"
        native_loc="file://"$(pwd)"/native_main"
    else
        if [ -n "$1" ] ; then
            native_version="$(curl -sSL https://raw.githubusercontent.com/tridactyl/tridactyl/"$1"/native/current_native_version 2>/dev/null)"
        else
            native_version="$(curl -sSL https://api.github.com/repos/tridactyl/native_messenger/releases/latest | grep "tag_name" | cut -d':' -f2- | sed 's|[^0-9\.]||g')"
        fi
        manifest_loc="https://raw.githubusercontent.com/tridactyl/native_messenger/$native_version/tridactyl.json"
        native_loc="https://github.com/tridactyl/native_messenger/releases/download/$native_version/native_main-$binary_suffix"
    fi

    install_to "$manifest_home" "$manifest_home"

    for flatpak_dir in ~/.var/app/*/.mozilla; do
        [ -d "$flatpak_dir" ] || continue
        echo
        echo "Detected flatpak installation in $flatpak_dir"
        install_to "$flatpak_dir/native-messaging-hosts/" "$HOME/.mozilla/native-messaging-hosts/"
    done

    echo
    echo "Successfully installed Tridactyl native messenger!"
    echo "Run ':native' in Firefox to check."
}

# install_to takes two arguments:
#  1. The path to the manifest home as seen by the install script.
#  2. The path to the manifest home as seen by Firefox.
#
# For regular Firefox installations, these are the same.  They are different in
# the case of sandboxed installations (like Flatpak).
install_to() {
    manifest_home_on_host="$1"
    manifest_home_in_sandbox="$2"

    mkdir -p "$manifest_home_on_host"

    manifest_file="$manifest_home_on_host/tridactyl.json"
    # For Flatpak installations, we must install the native binary inside
    # `~/.mozilla/native-messaging-hosts` as well, because everything outside
    # of `~/.mozilla` is wiped when restarted.
    native_binary_name="tridactyl_native_main"
    native_file="$manifest_home_on_host/$native_binary_name"

    echo "Installing manifest here: $manifest_home_on_host"
    echo "Installing script here: $native_file"

    curl -sSL --create-dirs -o "$manifest_file" "$manifest_loc"
    curl -sSL --create-dirs -o "$native_file" "$native_loc"

    if [ ! -f "$manifest_file" ] ; then
        echoerr "Failed to create '$manifest_file'. Please make sure that the directories exist and that you have the necessary permissions."
        exit 1
    fi

    if [ ! -f "$native_file" ] ; then
        echoerr "Failed to create '$native_file'. Please make sure that the directories exist and that you have the necessary permissions."
        exit 1
    fi

    sed -i.bak "s/REPLACE_ME_WITH_SED/$(sedEscape "$manifest_home_in_sandbox/$native_binary_name")/" "$manifest_file"
    chmod +x "$native_file"

    ## Apparently `curl`'d things don't get quarantined, so maybe we don't need this after all?
    # case "$OSTYPE" in
    #     darwin*)
    #         echo
    #         echo "Please log in as an administrator to give Tridactyl's messenger permission to run:"
    #         sudo xattr -d com.apple.quarantine "$native_file"
    #         ;;
    # esac
}

# Run the run function in a subshell so that it can be exited early if an error
# occurs
if ret="$(run "$@")"; then
    # Print captured output
    printf "%b\n" "$ret"
else
    # Print captured output, ${ret:+\n} adds a newline only if ret isn't empty
    printf "%b" "$ret${ret:+\n}"
    echoerr 'Failed to install!'
fi
