echo "Repair the Copy URL shortcut for profiles that predate its pinned extension id"

# Chromium derives an unpacked extension's id from its absolute load path when
# the manifest carries no key, and it never hands a suggested shortcut to one
# extension while another — even a long-gone one — still holds the
# registration. Profiles that first loaded Copy URL keyless (from
# ~/.local/share/omarchy before the package era, or from /usr/share before the
# id was pinned) therefore map Alt+Shift+L to a path-derived id that no longer
# exists, and the shortcut silently does nothing. Move those registrations to
# the pinned id and drop the ghost extension's leftover settings. The quattro
# upgrade already does this, but installs that upgraded before it learned to
# compute the per-user path-derived id were left stale.

stale_ids_output=$(python3 - <<'PY'
import hashlib
import os

def extension_id(path_bytes):
    digest = hashlib.sha256(path_bytes).digest()[:16]
    return "".join(chr(97 + (b >> 4)) + chr(97 + (b & 15)) for b in digest)

# Chromium canonicalizes --load-extension paths with realpath() before
# hashing, so symlinked path components registered the id of the resolved
# path. Resolve up to the parent of the omarchy directory but no further:
# ~/.local/share/omarchy is now a compatibility symlink to /usr/share/omarchy,
# so resolving the full path could never reproduce the id Chromium derived
# when the files really lived there.
home = os.path.expanduser("~")
suffix = "/.local/share/omarchy/default/chromium/extensions/copy-url"
share_path = "/usr/share/omarchy/default/chromium/extensions/copy-url"

seen = []
for candidate in (
    home + suffix,
    os.path.realpath(home) + suffix,
    os.path.realpath(home + "/.local/share") + "/omarchy/default/chromium/extensions/copy-url",
    share_path,
    os.path.realpath(share_path),
):
    stale_id = extension_id(os.fsencode(candidate))
    if stale_id not in seen:
        seen.append(stale_id)

print("\n".join(seen))
PY
)
readarray -t stale_ids <<<"$stale_ids_output"

stale_id_greps=()
for stale_id in "${stale_ids[@]}"; do
  stale_id_greps+=(-e "$stale_id")
done

profile_roots=(
  "$HOME/.config/chromium"
  "$HOME/.config/google-chrome"
  "$HOME/.config/google-chrome-beta"
  "$HOME/.config/google-chrome-unstable"
  "$HOME/.config/BraveSoftware/Brave-Browser"
  "$HOME/.config/BraveSoftware/Brave-Browser-Beta"
  "$HOME/.config/BraveSoftware/Brave-Browser-Nightly"
  "$HOME/.config/microsoft-edge"
  "$HOME/.config/microsoft-edge-beta"
  "$HOME/.config/microsoft-edge-dev"
  "$HOME/.config/vivaldi"
  "$HOME/.config/opera"
  "$HOME/.config/helium"
)

pending=()
for profile_root in "${profile_roots[@]}"; do
  [[ -d $profile_root ]] || continue

  for preferences in "$profile_root"/*/Preferences; do
    [[ -f $preferences ]] || continue
    grep -qF "${stale_id_greps[@]}" "$preferences" || continue
    pending+=("$preferences")
  done
done

(( ${#pending[@]} )) || exit 0

# A running browser holds Preferences in memory and rewrites the file on exit,
# reverting any edit — and possibly restoring a stale registration another
# repair just fixed on disk. While one runs, nothing on disk can be trusted,
# so fail: the migration stays pending and runs again at the next login, when
# browsers are not up yet. Repairs also erase every stale trace, so repaired
# profiles never re-trigger this gate.
if pgrep -x 'chromium|chrome|brave|msedge|vivaldi-bin|vivaldi|opera|helium' >/dev/null 2>&1; then
  echo "A running browser would undo the Copy URL shortcut repair." >&2
  echo "Close all browser windows, then run: omarchy-migrate" >&2
  exit 1
fi

for preferences in "${pending[@]}"; do
  python3 - "$preferences" "$preferences.omarchy-copy-url-repair.bak" \
    bgpiichlckmfanooecilcjemknkcpngb "${stale_ids[@]}" <<'PY'
import json
import shutil
import sys
from pathlib import Path

path = Path(sys.argv[1])
backup_path = Path(sys.argv[2])
new_id = sys.argv[3]
old_ids = set(sys.argv[4:])
preferences = json.loads(path.read_text())
extensions = preferences.get("extensions", {})
commands = extensions.get("commands", {})
settings = extensions.get("settings", {})
changed = False

for command in commands.values():
    if command.get("extension") in old_ids and command.get("command_name") == "copy-url":
        command["extension"] = new_id
        new_command = settings.get(new_id, {}).get("commands", {}).get("copy-url", {})
        if new_command:
            new_command["was_assigned"] = True
        changed = True

for old_id in old_ids:
    if settings.pop(old_id, None) is not None:
        changed = True

if changed:
    shutil.copy2(path, backup_path)
    path.write_text(json.dumps(preferences, separators=(",", ":")))
PY
done
