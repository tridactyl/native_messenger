#!/usr/bin/env bash
set -euo pipefail

nimble build -d:debug -Y
python3 test_native_main.py ./native_main
