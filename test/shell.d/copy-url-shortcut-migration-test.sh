#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command jq
require_command node
require_command python3

migration="$ROOT/migrations/1786643346.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

home="$test_dir/home"
preferences="$home/.config/chromium/Default/Preferences"
mkdir -p "$(dirname "$preferences")"

# The stale id is derived from the pre-package load path under the user's
# home, so compute it for the fixture home the same way Chromium would.
stale_id=$(node - <<JS
const crypto = require('crypto')
const hash = crypto.createHash('sha256').update('$home/.local/share/omarchy/default/chromium/extensions/copy-url').digest()
const alphabet = 'abcdefghijklmnop'
let id = ''
for (const byte of hash.subarray(0, 16)) {
  id += alphabet[byte >> 4]
  id += alphabet[byte & 0x0f]
}
process.stdout.write(id)
JS
)

write_stale_preferences() {
  jq -n --arg stale "$stale_id" '{extensions: {commands: {"linux:Alt+Shift+L": {command_name: "copy-url", extension: $stale, global: false}}, settings: {($stale): {commands: {"copy-url": {suggested_key: "Alt+Shift+L", was_assigned: true}}}, bgpiichlckmfanooecilcjemknkcpngb: {commands: {"copy-url": {suggested_key: "Alt+Shift+L"}}}}}}' >"$preferences"
}

stub_bin="$test_dir/bin"
mkdir -p "$stub_bin"

run_migration() {
  HOME="$home" PATH="$stub_bin:$PATH" bash -euo pipefail "$migration" >/dev/null 2>&1
}

# A running browser defers the repair so a rewrite-on-exit cannot revert it.
printf '#!/bin/bash\nexit 0\n' >"$stub_bin/pgrep"
chmod +x "$stub_bin/pgrep"
write_stale_preferences
before_hash=$(sha256sum "$preferences" | cut -d' ' -f1)

run_migration && fail "migration defers while a browser is running"
[[ $(sha256sum "$preferences" | cut -d' ' -f1) == "$before_hash" ]] ||
  fail "migration leaves preferences alone while a browser is running"
pass "migration defers the repair while a browser is running"

# With browsers closed the stale registration moves to the pinned id.
printf '#!/bin/bash\nexit 1\n' >"$stub_bin/pgrep"
run_migration || fail "migration repairs the shortcut when no browser is running"

jq -e --arg stale "$stale_id" '
  .extensions.commands["linux:Alt+Shift+L"].extension == "bgpiichlckmfanooecilcjemknkcpngb" and
  (.extensions.settings | has($stale) | not) and
  .extensions.settings.bgpiichlckmfanooecilcjemknkcpngb.commands["copy-url"].was_assigned == true
' "$preferences" >/dev/null || fail "migration moves the Copy URL shortcut to the pinned extension id"
[[ -f $preferences.omarchy-copy-url-repair.bak ]] ||
  fail "migration backs up preferences before the repair"
pass "migration moves the Copy URL shortcut to the pinned extension id"

# A second run must find nothing left to do.
rm "$preferences.omarchy-copy-url-repair.bak"
repaired_hash=$(sha256sum "$preferences" | cut -d' ' -f1)
run_migration || fail "migration reruns cleanly after the repair"
[[ $(sha256sum "$preferences" | cut -d' ' -f1) == "$repaired_hash" && ! -e $preferences.omarchy-copy-url-repair.bak ]] ||
  fail "migration is idempotent after the repair"
pass "migration is idempotent after the repair"

# The repair erases every stale trace, so a repaired profile must not
# re-trigger the running-browser deferral.
printf '#!/bin/bash\nexit 0\n' >"$stub_bin/pgrep"
run_migration || fail "migration does not defer for an already repaired profile"
pass "migration ignores repaired profiles even while a browser is running"
printf '#!/bin/bash\nexit 1\n' >"$stub_bin/pgrep"

# The keyless /usr/share era left one stale id shared by every install.
shared_stale_id=$(node - <<'JS'
const crypto = require('crypto')
const hash = crypto.createHash('sha256').update('/usr/share/omarchy/default/chromium/extensions/copy-url').digest()
const alphabet = 'abcdefghijklmnop'
let id = ''
for (const byte of hash.subarray(0, 16)) {
  id += alphabet[byte >> 4]
  id += alphabet[byte & 0x0f]
}
process.stdout.write(id)
JS
)

jq -n --arg stale "$shared_stale_id" '{extensions: {commands: {"linux:Alt+Shift+L": {command_name: "copy-url", extension: $stale, global: false}}, settings: {}}}' >"$preferences"
run_migration || fail "migration repairs the keyless /usr/share era registration"
jq -e '.extensions.commands["linux:Alt+Shift+L"].extension == "bgpiichlckmfanooecilcjemknkcpngb"' "$preferences" >/dev/null ||
  fail "migration moves the keyless /usr/share era registration to the pinned id"
pass "migration repairs the keyless /usr/share era registration"

# Chromium canonicalizes load paths, so a symlinked home registered the id of
# the resolved home path. Quattro installs also leave ~/.local/share/omarchy
# as a compatibility symlink to /usr/share/omarchy, so the historical id can
# only be rebuilt by resolving the home directory alone — resolving the full
# legacy path would follow that symlink to the wrong place.
real_home="$test_dir/real-home"
linked_home="$test_dir/linked-home"
mkdir -p "$real_home/.config/chromium/Default" "$real_home/.local/share"
ln -s "$real_home" "$linked_home"
ln -s "$test_dir/elsewhere" "$real_home/.local/share/omarchy"

resolved_stale_id=$(node - <<JS
const crypto = require('crypto')
const hash = crypto.createHash('sha256').update('$real_home/.local/share/omarchy/default/chromium/extensions/copy-url').digest()
const alphabet = 'abcdefghijklmnop'
let id = ''
for (const byte of hash.subarray(0, 16)) {
  id += alphabet[byte >> 4]
  id += alphabet[byte & 0x0f]
}
process.stdout.write(id)
JS
)

linked_preferences="$real_home/.config/chromium/Default/Preferences"
jq -n --arg stale "$resolved_stale_id" '{extensions: {commands: {"linux:Alt+Shift+L": {command_name: "copy-url", extension: $stale, global: false}}, settings: {}}}' >"$linked_preferences"
HOME="$linked_home" PATH="$stub_bin:$PATH" bash -euo pipefail "$migration" >/dev/null 2>&1 ||
  fail "migration repairs a profile registered through a symlinked home"
jq -e '.extensions.commands["linux:Alt+Shift+L"].extension == "bgpiichlckmfanooecilcjemknkcpngb"' "$linked_preferences" >/dev/null ||
  fail "migration resolves symlinked homes to the id Chromium actually registered"
pass "migration repairs a profile registered through a symlinked home"

# Symlinks below the home directory count too: a relocated ~/.local means
# Chromium hashed the resolved location, not the textual home path.
dotlocal_home="$test_dir/dotlocal-home"
moved_local="$test_dir/moved-local"
mkdir -p "$dotlocal_home/.config/chromium/Default" "$moved_local/share"
ln -s "$moved_local" "$dotlocal_home/.local"

moved_stale_id=$(node - <<JS
const crypto = require('crypto')
const hash = crypto.createHash('sha256').update('$moved_local/share/omarchy/default/chromium/extensions/copy-url').digest()
const alphabet = 'abcdefghijklmnop'
let id = ''
for (const byte of hash.subarray(0, 16)) {
  id += alphabet[byte >> 4]
  id += alphabet[byte & 0x0f]
}
process.stdout.write(id)
JS
)

moved_preferences="$dotlocal_home/.config/chromium/Default/Preferences"
jq -n --arg stale "$moved_stale_id" '{extensions: {commands: {"linux:Alt+Shift+L": {command_name: "copy-url", extension: $stale, global: false}}, settings: {}}}' >"$moved_preferences"
HOME="$dotlocal_home" PATH="$stub_bin:$PATH" bash -euo pipefail "$migration" >/dev/null 2>&1 ||
  fail "migration repairs a profile registered through a symlinked ~/.local"
jq -e '.extensions.commands["linux:Alt+Shift+L"].extension == "bgpiichlckmfanooecilcjemknkcpngb"' "$moved_preferences" >/dev/null ||
  fail "migration resolves symlinked ~/.local to the id Chromium actually registered"
pass "migration repairs a profile registered through a symlinked ~/.local"
