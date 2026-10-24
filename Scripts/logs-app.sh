#!/usr/bin/env bash
set -euo pipefail

/usr/bin/log stream \
  --style compact \
  --predicate 'subsystem == "com.tcs.wallpaper"' \
  --level debug
