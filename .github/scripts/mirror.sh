#!/usr/bin/env bash
set -eo pipefail
rsync -avz -f'P .git/***'  -f'H .git/***' --delete-excluded --exclude-from ./.github/scripts/mirror.exclude  --include-from ./.github/scripts/mirror.include --include '*/' --exclude '*' . "$1" --prune-empty-dirs  -v

