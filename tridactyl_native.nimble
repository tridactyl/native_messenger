# Package

author        = "Oliver Blanthorn"
description   = "Native messenger for Tridactyl, a vim-like web-extension"
license       = "BSD-2"
version       = "0.6.0"
srcDir        = "src"
bin           = @["native_main"]

# Dependencies

requires "nim >= 2.0.0"
requires "tempfile >= 0.1.0"
requires "regex >= 0.20.2"

task test, "Run protocol and CLI integration tests":
  when defined(windows):
    exec "python tests/test_native.py"
  else:
    exec "python3 tests/test_native.py"
