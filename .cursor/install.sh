#!/bin/bash

# Cloud Agent environment bootstrap for Omarchy.
#
# Omarchy targets Arch Linux, where the tools below (and the OMARCHY_PATH
# session contract described in AGENTS.md) are provided by the base system and
# the uwsm session. The Cloud Agent base image is Ubuntu, so this script
# installs the equivalents and reproduces that runtime contract. It is
# idempotent: it can run repeatedly and against a cached/partially prepared VM.

set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SRC_DIR="$HOME/src"

# --- System packages ------------------------------------------------------
# python-is-python3: test/cli invokes `python`.
# gawk: omarchy scripts use gawk extensions such as strtonum(); Ubuntu's default
#   awk is mawk, which lacks them.
# lua5.4: omarchy scripts and the Hyprland config call `lua`.
# imagemagick: omarchy-bar-text-color samples wallpapers via ImageMagick.
# iproute2: provides `ip`, used to detect the active network interface.
# jq: used throughout the CLI and its tests.
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  python-is-python3 \
  gawk \
  lua5.4 \
  imagemagick \
  iproute2 \
  jq

# Make gawk the default awk so strtonum() and friends resolve.
sudo update-alternatives --install /usr/bin/awk awk /usr/bin/gawk 100

# omarchy calls the interpreter as `lua`; Ubuntu ships it as lua5.4.
sudo update-alternatives --install /usr/bin/lua lua-interpreter /usr/bin/lua5.4 100

# Omarchy uses ImageMagick 7's unified `magick` entrypoint. Ubuntu ships
# ImageMagick 6 (`convert`), which accepts the same options the scripts pass, so
# expose a thin `magick` shim over it.
sudo tee /usr/local/bin/magick >/dev/null <<'MAGICK'
#!/bin/bash
exec /usr/bin/convert "$@"
MAGICK
sudo chmod +x /usr/local/bin/magick

# --- Sibling checkouts ----------------------------------------------------
# A couple of packaging-coverage tests read the sibling omarchy-pkgs and
# omarchy-iso repositories. Both are public.
mkdir -p "$SRC_DIR"
clone_or_update() {
  local url=$1 dir=$2
  if [[ -d $dir/.git ]]; then
    git -C "$dir" fetch --depth 1 origin HEAD --quiet && \
      git -C "$dir" reset --hard FETCH_HEAD --quiet || true
  else
    git clone --depth 1 "$url" "$dir"
  fi
}
clone_or_update https://github.com/omacom-io/omarchy-pkgs "$SRC_DIR/omarchy-pkgs"
clone_or_update https://github.com/omacom-io/omarchy-iso "$SRC_DIR/omarchy-iso"

# --- Runtime session contract ---------------------------------------------
# Reproduce the ambient environment omarchy runtime code expects: OMARCHY_PATH
# exported and omarchy-* commands on PATH (AGENTS.md). Point the packaging tests
# at the sibling checkouts too. Login shells (including tmux) read
# /etc/profile.d; interactive shells read ~/.bashrc.
env_block() {
  cat <<ENV
# >>> omarchy cloud-agent env >>>
export OMARCHY_PATH="$REPO_DIR"
case ":\$PATH:" in
  *":\$OMARCHY_PATH/bin:"*) ;;
  *) export PATH="\$OMARCHY_PATH/bin:\$PATH" ;;
esac
export OMARCHY_PKGS_PATH="$SRC_DIR/omarchy-pkgs"
export OMARCHY_ISO_PATH="$SRC_DIR/omarchy-iso"
# <<< omarchy cloud-agent env <<<
ENV
}

env_block | sudo tee /etc/profile.d/omarchy-dev.sh >/dev/null

if [[ -w ${HOME}/.bashrc || ! -e ${HOME}/.bashrc ]]; then
  bashrc="$HOME/.bashrc"
  if ! grep -q '>>> omarchy cloud-agent env >>>' "$bashrc" 2>/dev/null; then
    { printf '\n'; env_block; } >>"$bashrc"
  fi
fi

echo "Omarchy Cloud Agent environment ready (OMARCHY_PATH=$REPO_DIR)."
