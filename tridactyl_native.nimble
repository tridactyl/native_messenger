# Package

version       = "0.2.0"
author        = "Oliver Blanthorn"
description   = "Native messenger for Tridactyl, a vim-like web-extension"
license       = "BSD-2"
srcDir        = "src"
bin           = @["native_main.py"]

# Dependencies

requires "nim >= 1.4.2"
requires "struct >= 0.2.0"
requires "tempfile >= 0.1.0"
