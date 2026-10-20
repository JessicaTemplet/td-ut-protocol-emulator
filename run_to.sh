#!/bin/bash
# Partial LibreLane run for fast PDN/placement iteration, same container +
# PDK + merged config as `tt_tool.py --harden --ihp`, but into its own run
# dir (runs/<tag>) and stopping early.
#   usage: ./run_to.sh <tag> [librelane args, e.g. --to OpenROAD.GeneratePDN]
set -e
cd "$(dirname "$0")"
TT_SETUP=${TT_SETUP:-$HOME/ttsetup}
source "$TT_SETUP/venv/bin/activate"
export PDK_ROOT=${PDK_ROOT:-$TT_SETUP/pdk_cmos5l} PDK=ihp-sg13cmos5l
TAG=$1; shift
python tt/tt_tool.py --ihp --create-user-config >/dev/null
rm -rf "runs/$TAG"
mkdir -p "runs/$TAG"
python -m librelane --pdk-root "$PDK_ROOT" --docker-no-tty --dockerized \
  --pdk ihp-sg13cmos5l --manual-pdk --run-tag "$TAG" --force-run-dir "runs/$TAG" --hide-progress-bar \
  src/config_merged.json "$@"
