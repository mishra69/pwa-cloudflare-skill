#!/usr/bin/env bash
#
# Compare an app's copies of the skill's shared assets against the canonical
# ones, and optionally update them.
#
# Copying beats a shared import for these files — each app stays cloneable and
# deployable on its own — but the cost is drift. This makes drift visible.
#
# Usage, from the app's root directory:
#   /path/to/skills/pwa-cloudflare/sync-assets.sh           # report only
#   /path/to/skills/pwa-cloudflare/sync-assets.sh --apply   # copy skill -> app
#
# Reads a `.skill-assets` manifest in the app root, one mapping per line:
#   oidc.js          worker/lib/oidc.js
#   pwa-install.js   frontend/js/pwa-install.js
# Blank lines and #-comments are ignored.

set -uo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$SKILL_DIR/assets"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

if [ ! -f .skill-assets ]; then
  echo "error: no .skill-assets manifest here. Run from the app root." >&2
  exit 1
fi

sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# The skill's own version, and the one this app last synced from. Recording it
# turns "what changed since?" into a git diff over the skill between those tags.
SKILL_VERSION=$(sed -n 's/^version: *//p' "$SKILL_DIR/SKILL.md" | head -1)
APP_VERSION=$(sed -n 's/^# *skill-version: *//p' .skill-assets | head -1)
[ -z "$SKILL_VERSION" ] && SKILL_VERSION="(unversioned)"
[ -z "$APP_VERSION" ] && APP_VERSION="(not recorded)"
echo "skill $SKILL_VERSION | this app synced from $APP_VERSION"
if [ "$APP_VERSION" != "$SKILL_VERSION" ] && [ "$APP_VERSION" != "(not recorded)" ]; then
  echo "  → behind. What changed:  git -C $SKILL_DIR diff $APP_VERSION..$SKILL_VERSION ."
fi
echo

same=0; differs=0; missing=0; updated=0

while read -r asset target; do
  case "${asset:-}" in ''|\#*) continue ;; esac
  [ -z "${target:-}" ] && continue

  src="$ASSETS/$asset"
  if [ ! -f "$src" ]; then
    printf '  ?  %-34s no such asset in the skill\n' "$asset"; missing=$((missing+1)); continue
  fi
  if [ ! -f "$target" ]; then
    printf '  +  %-34s missing here\n' "$target"; missing=$((missing+1))
    if [ $APPLY = 1 ]; then mkdir -p "$(dirname "$target")" && cp "$src" "$target" && updated=$((updated+1)); fi
    continue
  fi

  if [ "$(sha "$src")" = "$(sha "$target")" ]; then
    printf '  =  %-34s in sync\n' "$target"; same=$((same+1))
  else
    printf '  !  %-34s DIFFERS from skill copy\n' "$target"; differs=$((differs+1))
    if [ $APPLY = 1 ]; then cp "$src" "$target" && updated=$((updated+1)); fi
  fi
done < .skill-assets

echo
if [ $APPLY = 1 ]; then
  # Record what we synced from, so the next run can report the gap.
  if grep -q '^# *skill-version:' .skill-assets; then
    if sed --version >/dev/null 2>&1; then
      sed -i "s/^# *skill-version:.*/# skill-version: $SKILL_VERSION/" .skill-assets
    else
      sed -i '' "s/^# *skill-version:.*/# skill-version: $SKILL_VERSION/" .skill-assets
    fi
  else
    printf '\n# skill-version: %s\n' "$SKILL_VERSION" >> .skill-assets
  fi
  echo "$updated file(s) updated from the skill — review with: git diff"
  echo "recorded skill-version $SKILL_VERSION in .skill-assets"
else
  echo "$same in sync, $differs differing, $missing missing"
  # Direction isn't tracked: a difference means the app was customised, or the
  # skill moved on, or both. `git diff` after --apply is what tells them apart,
  # which is why this refuses to guess.
  [ $differs -gt 0 ] && echo "re-run with --apply to take the skill's version (the app is in git; diff before committing)"
fi
exit 0
