#!/usr/bin/env bash
# Open (or update) a stable-branch PR that fixes a bucket of vulnerabilities.
#
# Usage: open-fix-pr.sh <bucket>
#   bucket = safe | forceNonBreaking | breaking
#
# Reads audit-summary.json from the working directory.
# Requires: GH_TOKEN, GITHUB_BASE_REF or GITHUB_REF_NAME.
set -euo pipefail

BUCKET="${1:?bucket required: safe | forceNonBreaking | breaking}"

case "$BUCKET" in
  safe)
    BRANCH="auto-audit/fix-safe"
    TITLE="chore(security): in-range npm audit fixes"
    COMMIT_MSG="chore(security): apply in-range npm audit fixes"
    DESC="Applies \`npm audit fix\` for vulnerabilities whose fix is within the stated SemVer range."
    ;;
  forceNonBreaking)
    BRANCH="auto-audit/fix-force"
    TITLE="chore(security): non-breaking out-of-range upgrades"
    COMMIT_MSG="chore(security): upgrade out-of-range deps (non-breaking)"
    DESC="Upgrades dependencies whose fix is outside the stated SemVer range but is **not** SemVer-major."
    ;;
  breaking)
    BRANCH="auto-audit/fix-breaking"
    TITLE="chore(security)!: SemVer-major upgrades for vulnerabilities"
    COMMIT_MSG="chore(security)!: apply SemVer-major upgrades for vulnerabilities"
    DESC="**⚠️ Potentially breaking** - applies SemVer-major upgrades. Review each package's changelog before merging."
    ;;
  *) echo "unknown bucket: $BUCKET" >&2; exit 2 ;;
esac

BASE="${GITHUB_BASE_REF:-$GITHUB_REF_NAME}"
git fetch origin "$BASE"
git checkout -B "$BRANCH" "origin/$BASE"
npm ci

# Apply the fix.
if [ "$BUCKET" = "safe" ]; then
  # in-range fixes - let npm pick everything, including workspace packages
  npm audit fix || true
  npm audit fix --workspaces || true
else
  TARGETS=$(node -e "console.log(require('./audit-summary.json').${BUCKET}.map(e=>e.target).join(' '))")
  if [ -z "$TARGETS" ]; then
    echo "No targets resolved for bucket '$BUCKET'; nothing to do."
    exit 0
  fi
  # shellcheck disable=SC2086
  npm install --save-exact $TARGETS
fi

# Collect all changed package.json files (root + workspaces)
CHANGED_PKGS=$(git diff --name-only | grep -E '(^|/)package\.json$' || true)
if [ -z "$CHANGED_PKGS" ] && git diff --quiet -- package-lock.json; then
  echo "No changes produced; skipping PR."
  exit 0
fi

# Skip if the remote stable branch already has the same fix.
if git fetch origin "$BRANCH" 2>/dev/null; then
  REMOTE_DIFF=$(git diff --name-only "origin/$BRANCH" | grep -E '(^|/)package(-lock)?\.json$' || true)
  if [ -z "$REMOTE_DIFF" ]; then
    echo "Remote branch $BRANCH already has these fixes; nothing to do."
    exit 0
  fi
fi

# Build a per-package bullet list for the PR body.
LIST=$(node -e "
  const b = require('./audit-summary.json').${BUCKET};
  console.log(b.map(e => e.target
    ? '- ' + e.name + ' → ' + e.target + ' (' + e.severity + ')'
    : '- ' + e.name + ' (' + e.severity + ')'
  ).join('\n'));
")

# Stage root + any workspace package.json files that changed
# shellcheck disable=SC2046
git add package-lock.json $(git diff --name-only | grep -E '(^|/)package\.json$' || true)
git commit -m "$COMMIT_MSG"
git push --force-with-lease origin "$BRANCH"

BODY=$'Automated PR from auto-audit workflow.\n\n'"$DESC"$'\n\n'"$LIST"

if [ -z "$(gh pr list --head "$BRANCH" --state open --json number --jq '.[].number')" ]; then
  gh pr create --base "$BASE" --head "$BRANCH" --title "$TITLE" --body "$BODY"
else
  echo "Open PR for $BRANCH already exists; force-push updated it in place."
fi
