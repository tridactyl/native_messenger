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

run() {
    set -e

    XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/tridactyl"
    XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/tridactyl"

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

    if [ -n "$1" ] ; then
        native_version="$(curl -sSL https://raw.githubusercontent.com/tridactyl/tridactyl/"$1"/native/current_native_version 2>/dev/null)"
    else
        native_version="$(curl -sSL https://api.github.com/repos/tridactyl/native_messenger/releases/latest | grep "tag_name" | cut -d':' -f2- | sed 's|[^0-9\.]||g')"
    fi
    manifest_loc="https://raw.githubusercontent.com/tridactyl/native_messenger/$native_version/tridactyl.json"
    native_loc="https://github.com/tridactyl/native_messenger/releases/download/$native_version/native_main-$binary_suffix"


    mkdir -p "$manifest_home" "$XDG_DATA_HOME"

    manifest_file="$manifest_home/tridactyl.json"
    native_file="$XDG_DATA_HOME/native_main"

    echo "Installing manifest here: $manifest_home"
    echo "Installing script here: XDG_DATA_HOME: $XDG_DATA_HOME"


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

    sed -i.bak "s/REPLACE_ME_WITH_SED/$(sedEscape "$native_file")/" "$manifest_file"
    chmod +x "$native_file"

    ## Apparently `curl`'d things don't get quarantined, so maybe we don't need this after all?
    # case "$OSTYPE" in
    #     darwin*)
    #         echo
    #         echo "Please log in as an administrator to give Tridactyl's messenger permission to run:"
    #         sudo xattr -d com.apple.quarantine "$native_file"
    #         ;;
    # esac

    echo
    echo "Successfully installed Tridactyl native messenger!"
    echo "Run ':native' in Firefox to check."
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
