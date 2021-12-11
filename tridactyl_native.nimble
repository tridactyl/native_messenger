# Package

author        = "Oliver Blanthorn"
description   = "Native messenger for Tridactyl, a vim-like web-extension"
license       = "BSD-2"
srcDir        = "src"
bin           = @["native_main"]

# Dependencies

requires "nim >= 1.2.0"
requires "tempfile >= 0.1.0"
