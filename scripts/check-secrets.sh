#!/bin/sh
# Stops private details reaching this public repo. Run by the git hooks in .githooks:
#   scripts/check-secrets.sh staged          what's about to be committed
#   scripts/check-secrets.sh commits <range> commits about to be pushed, as rev-list arguments
#
# It blocks:
#   - the signing values in Local.xcconfig, and any string listed in Local.secrets (git-ignored,
#     one per line: your R2 account ID, bucket name, photo domain, email, anything else private)
#   - R2 endpoints and public bucket URLs with a real account ID, and 64-character hex keys
#   - home folder paths and device IDs
#   - photos, signing files and local config files
#   - commits whose author email is a computer's local address
# A line with "secret-scan: allow" in it, or containing a value listed in .secret-scan-allow, is
# skipped, for public example values in tests.
set -eu
cd "$(dirname "$0")/.."

mode=${1:-staged}
problems=""
note() { problems="$problems
  - $1"; }

# Private strings: signing values (unless still the example ones) and Local.secrets.
private=""
if [ -f Local.xcconfig ]; then
  private=$(sed -n -E 's/^(DEVELOPMENT_TEAM|BUNDLE_ID_PREFIX) *= *//p' Local.xcconfig | grep -v -x -e YOUR_TEAM_ID -e com.example || true)
fi
if [ -f Local.secrets ]; then
  private="$private
$(grep -v -e '^#' -e '^[[:space:]]*$' Local.secrets || true)"
fi

case "$mode" in
  staged)
    files=$(git diff --cached --name-only --diff-filter=ACMR)
    added=$(git diff --cached -U0 --no-color --diff-filter=ACMR | grep '^+' | grep -v '^+++' || true)
    ;;
  commits)
    shift
    files=$(git log --name-only --format= --diff-filter=ACMR "$@" | sort -u)
    added=$(git log -p -U0 --no-color --format= --diff-filter=ACMR "$@" | grep '^+' | grep -v '^+++' || true)
    emails=$(git log --format='%ae %ce' "$@" | tr ' ' '\n' | sort -u)
    for email in $emails; do
      case "$email" in *.local|*.lan|*.home|*.localdomain) note "a commit uses the local email $email (see README: Keeping this repo clean)";; esac
    done
    ;;
  *) echo "usage: $0 staged | commits <rev-list arguments>" >&2; exit 2 ;;
esac

for file in $files; do
  case "$file" in
    Local.xcconfig|Local.secrets|.env|.env.*|*.mobileprovision|*.p12|*.cer|*.ipa)
      note "$file must never be committed" ;;
    Fixtures/originals/*|*.heic|*.HEIC|*.jpg|*.JPG|*.jpeg|*.png|*.PNG|*.mov)
      case "$file" in *.xcassets/*) ;; *) note "$file looks like a photo (cover art is copyrighted)" ;; esac ;;
  esac
done

scan=$(printf '%s\n' "$added" | grep -v 'secret-scan: allow' || true)
if [ -f .secret-scan-allow ]; then
  allowed=$(grep -v -e '^#' -e '^[[:space:]]*$' .secret-scan-allow || true)
  [ -z "$allowed" ] || scan=$(printf '%s\n' "$scan" | grep -v -F -e "$allowed" || true)
fi
printf '%s\n' "$private" | while IFS= read -r value; do
  [ -n "$value" ] || continue
  if printf '%s\n' "$scan" | grep -q -F -- "$value"; then echo "x"; fi
done | grep -q x && note "a value from Local.xcconfig or Local.secrets"

match() { printf '%s\n' "$scan" | grep -q -E -- "$1" && note "$2"; return 0; }
match '[0-9a-f]{32}\.([a-z]+\.)?r2\.cloudflarestorage\.com' "an R2 endpoint with a real account ID"
match 'pub-[0-9a-f]{32}\.r2\.dev' "a public r2.dev bucket URL"
match '(^|[^0-9a-f])[0-9a-f]{64}([^0-9a-f]|$)' "a 64-character hex string, which is what R2 secret keys look like"
match '/Users/[A-Za-z]' "a home folder path"
match '[0-9A-F]{8}-[0-9A-F]{16}' "an iPhone device ID"

if [ -n "$problems" ]; then
  echo "Blocked: this would put private details in the public repo:$problems" >&2
  echo "Remove them, or mark a public example value with \"secret-scan: allow\" on its line." >&2
  exit 1
fi
