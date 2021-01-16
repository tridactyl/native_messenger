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

It therefore greatly increases the amount of damage bugs in Tridactyl can do to your machine, although, arguably, not to your life, since almost all of that is on the internet anyway. 

# Installation

Two options: run `:nativeinstall` in Tridactyl and follow the instructions. Otherwise download and run `installers/install.sh`, or `installers/windows.ps1` for Windows, from this repository

# Building

1. Install nim and nimble.
2. `nimble build`

# Testing

DIY testing:

```
./gen_native_message.py cmd..getconfigpath | ./native_main | cut -b4- | jq 'walk( if type == "object" then with_entries(select(.value != null)) else . end)'
```

Swap `native_main` for the old `native_main.py` messenger to check compat.
