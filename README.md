<h1 align="center">
<br>
<img src="assets/tridactyl_native.png" alt="Tridactyl Native Logo">
<br>
Tridactyl native messenger
<br>
</h1>

# What does it do?

This small application allows [Tridactyl](https://github.com/tridactyl/tridactyl) to communicate with your system, allowing Tridactyl to:

- read files on your computer, including "RC" configuration files
- write files to your computer
- launch applications, including opening `about:*` tabs in Firefox
- and generally do arbitrary stuff in userspace.
- from version 0.6.0 onwards, if `:set nativecontrol true` is set in the extension it can also send commands to Firefox.

It therefore greatly increases the amount of damage bugs in Tridactyl can do to your machine, although, arguably, not to your life, since almost all of that is on the internet anyway. 

# Installation

Three options:

- Run `:nativeinstall` in Tridactyl and follow the instructions.
- Download and run `installers/install.sh`, or `installers/windows.ps1` for Windows, from this repository.
- Clone the repository and build it locally, then run `./installers/install.sh local`.

# Building

1. Install nim and nimble.
2. `nimble build`

# Testing

```
nimble build
nimble test
```

For manual compatibility testing:

```
./gen_native_message.py cmd..getconfigpath | ./native_main | cut -b4- | jq 'walk( if type == "object" then with_entries(select(.value != null)) else . end)'
```

Swap `native_main` for the old `native_main.py` messenger to check compat.

# Controlling Firefox via the messenger

0.6.0+ supports sending an ex command to Firefox. First enable it in Tridactyl 1.26.0+ with `:set nativecontrol true`, then run:

```
~/.local/share/tridactyl/native_main --request 'tabopen https://example.com'
```

The default Windows path is `%USERPROFILE%\.tridactyl\native_main.exe`. If `XDG_DATA_HOME` is set, the Unix path is `$XDG_DATA_HOME/tridactyl/native_main`.

If more than one Firefox instance has opted in, the command reports their instance IDs. Select one by full ID or a unique prefix:

```
native_main --request 'reload' --instance 0123abcd
```

The bridge binds an ephemeral port on `127.0.0.1`, i.e. not accessible on the local network. Each native instance publishes a random ID, port and high-entropy authentication token in its per-user cache directory. 

If you wish to reverse-engineer the protocol for doing stupid stuff like controlling Firefox across the network, you'l need to grab that token and forward the port.
