#!/usr/bin/env bash
set -o pipefail
set -e
nimble build -d:debug
chmod +x native_main
cp native_main ~/.local/share/tridactyl/native_main
time printf '%c\0\0\0{"cmd": "run", "command": "echo $PATH"}' 39 | ./native_main
time printf '%c\0\0\0{"cmd": "version"}' 39 | ./native_main
# time printf '%c\0\0\0{"cmd": "read", "file": "$HOME/test"}' 39 | ./native_main
# time printf '%c\0\0\0{"cmd": "version"}' 39 | ~/.local/share/tridactyl/native_main.py # approx 100ms
# time printf '%c\0\0\0{"cmd": "run", "command": "echo $PATH"}' 39 | ~/.local/share/tridactyl/native_main.py # approx 100ms
