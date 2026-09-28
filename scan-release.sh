#!/bin/bash
# Release gate: refuse to publish if any tracked file carries a secret, Apple
# signing material, or personal data. Scans the files git tracks (what a
# GitHub Release's source archive contains), text files only.
#
#   ./scan-release.sh [repo-dir]      exit 0 = clean, 1 = hits, 2 = usage
#
# Categories:
#   SECRET  private-key blocks, known token formats, credential literals,
#           credentials in URLs — never allowlisted by default
#   APPLE   .p8 / .p12 / .cer / .mobileprovision / keychain files, AuthKey
#           references, App Store Connect key id + issuer, Sparkle private key
#   PII     e-mail addresses, IPv4 addresses, phone numbers, home directories
#
# Allowlist: .releasescan-allow at the repo root, one extended regex per line
# (# comments). A reported line matching any entry is dropped. Use it for test
# fixtures and example addresses, not for real credentials — move those out.
#
# If gitleaks is installed, its history scan runs too.
set -uo pipefail
REPO="${1:-.}"
[ -d "$REPO" ] || { echo "usage: $0 [repo-dir]" >&2; exit 2; }
cd "$REPO" || exit 2
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "$REPO is not a git repository" >&2; exit 2; }

ALLOW=".releasescan-allow"
hits=0
report() {  # report CATEGORY NAME <grep -n output>
  local cat="$1" name="$2" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -f "$ALLOW" ] && grep -q -E -f <(grep -v -E '^[[:space:]]*(#|$)' "$ALLOW") <<<"$line"; then continue; fi
    echo "$line  [$cat/$name]"
    hits=$((hits+1))
  done
}

# Text files only; git knows which are binary.
FILES=$(git ls-files -z | xargs -0 grep -I -l '' 2>/dev/null | grep -v -x "$ALLOW" || true)
scan() {  # scan CATEGORY NAME REGEX [extra grep flags]
  local cat="$1" name="$2" re="$3"; shift 3
  [ -n "$FILES" ] || return 0
  report "$cat" "$name" < <(printf '%s\n' "$FILES" | xargs grep -n -E "$@" -- "$re" 2>/dev/null || true)
}

# --- SECRET ---------------------------------------------------------------
scan SECRET private-key      '-----BEGIN [A-Z ]*PRIVATE KEY-----'
scan SECRET github-token     'gh[pousr]_[A-Za-z0-9]{20,}'
scan SECRET openai-key       'sk-[A-Za-z0-9_-]{20,}'
scan SECRET aws-access-key   'AKIA[0-9A-Z]{16}'
scan SECRET slack-token      'xox[baprs]-[A-Za-z0-9-]{10,}'
scan SECRET google-api-key   'AIza[0-9A-Za-z_-]{30,}'
scan SECRET stripe-key       '[sr]k_(live|test)_[A-Za-z0-9]{16,}'
scan SECRET jwt              'eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}'
scan SECRET url-credentials  '://[^/:@[:space:]]+:[^/@[:space:]]+@'
# A credential-ish name assigned a quoted literal of 6+ chars that is not a
# placeholder (REPLACE_WITH…, <…>, ${…}, example, changeme, xxx…).
CRED='(passw(or)?d|passwd|secret|api[_-]?key|apikey|auth[_-]?token|access[_-]?token|private[_-]?key)[A-Za-z0-9_]*[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{6,}["'"'"']'
PLACEHOLDER='REPLACE_WITH|<[^>]*>|\$\{|\$[A-Z_]+|example|changeme|placeholder|xxx+|\*\*\*|your[_ -]'
if [ -n "$FILES" ]; then
  report SECRET credential-literal < <(printf '%s\n' "$FILES" | xargs grep -n -i -E -- "$CRED" 2>/dev/null | grep -v -i -E "$PLACEHOLDER" || true)
fi
# --- APPLE ----------------------------------------------------------------
report APPLE signing-file < <(git ls-files | grep -n -E '\.(p8|p12|pfx|cer|crt|mobileprovision|provisionprofile|keychain(-db)?)$' | sed 's/^\([0-9]*\):/\1:0:/' || true)
scan APPLE authkey-reference 'AuthKey_[A-Z0-9]{10}\.p8'
scan APPLE asc-key-id        '(KEY_ID|key_id|api_key_id|apiKeyId|keyId)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Z0-9]{10}["'"'"']?'
scan APPLE asc-issuer        '(ISSUER|issuer|issuer_id|issuerId)[[:space:]]*[:=][[:space:]]*["'"'"']?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
scan APPLE sparkle-private-key 'SUPrivateEDKey|-----BEGIN ED25519'
# --- PII ------------------------------------------------------------------
scan PII email               '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
scan PII ipv4                '(^|[^0-9.])((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])([^0-9.]|$)'
scan PII phone               '\+[0-9]{1,3}[ -]?[0-9(][0-9 ()-]{5,}[0-9]'
scan PII home-directory      '(/Users|/home)/[A-Za-z0-9._-]+'

# --- history, when a real scanner is installed -----------------------------
if command -v gitleaks >/dev/null 2>&1; then
  if ! gitleaks git --no-banner --redact -v . >/dev/null 2>&1; then
    echo "gitleaks: findings in git history (run: gitleaks git -v .)  [SECRET/history]"
    hits=$((hits+1))
  fi
fi

if [ "$hits" -gt 0 ]; then
  echo "scan-release: $hits hit(s); fix or allowlist test fixtures in $ALLOW" >&2
  exit 1
fi
echo "scan-release: clean"
