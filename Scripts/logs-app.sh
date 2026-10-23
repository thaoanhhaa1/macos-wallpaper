#!/usr/bin/env bash
set -euo pipefail

/usr/bin/log stream \
  --style compact \
  --predicate 'subsystem == "com.local.wallpaperapp"' \
  --level debug
