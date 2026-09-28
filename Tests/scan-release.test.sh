#!/bin/bash
# Tests for scan-release.sh: plants secrets and PII in throwaway git repos
# and checks the scanner's exit code and report. Run: Tests/scan-release.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$ROOT/scan-release.sh"
TMP=$(mktemp -d)
trap '/bin/rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; }

mkrepo() {  # mkrepo NAME → path; a fresh repo with one clean file
  local d="$TMP/$1"; mkdir -p "$d"; cd "$d"
  git init -q; git config user.email t@example.com; git config user.name t
  echo 'let greeting = "hello"' > Clean.swift
  git add . && git commit -q -m init
  echo "$d"
}

echo "scan-release.sh"

# 1. clean repo → exit 0, says clean
R=$(mkrepo clean)
if out=$("$SCAN" "$R" 2>&1); then [[ "$out" == *"clean"* ]] && ok "clean repo exits 0 and reports clean" || bad "clean repo: no 'clean' in output: $out"
else bad "clean repo exited non-zero: $out"; fi

# 2. AWS key → exit 1, names the file and category
R=$(mkrepo aws); cd "$R"; echo 'aws_key = "AKIAIOSFODNN7EXAMPLE"' > Config.swift; git add . && git commit -q -m k
if out=$("$SCAN" "$R" 2>&1); then bad "AWS key not caught"
else [[ "$out" == *"Config.swift:1"*"SECRET"* ]] && ok "AWS key caught with path:line and SECRET" || bad "AWS key: wrong report: $out"; fi

# 3. private key block → exit 1
R=$(mkrepo pem); cd "$R"; printf -- '-----BEGIN PRIVATE KEY-----\nMIIabc\n-----END PRIVATE KEY-----\n' > key.txt; git add . && git commit -q -m k
"$SCAN" "$R" >/dev/null 2>&1 && bad "private key block not caught" || ok "private key block caught"

# 4. password literal → exit 1; placeholder literal → allowed
R=$(mkrepo pw); cd "$R"; echo 'let password = "hunter2hunter2"' > A.swift; git add . && git commit -q -m k
"$SCAN" "$R" >/dev/null 2>&1 && bad "password literal not caught" || ok "password literal caught"
echo 'let password = "REPLACE_WITH_PASSWORD"' > A.swift; git commit -qam p
"$SCAN" "$R" >/dev/null 2>&1 && ok "placeholder literal allowed" || bad "placeholder literal wrongly caught"

# 5. GitHub token and credentials in a URL → exit 1
R=$(mkrepo gh); cd "$R"; echo 'token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef123456"' > A.swift; echo 'https://bob:pa55word@example.com/x' > B.txt; git add . && git commit -q -m k
out=$("$SCAN" "$R" 2>&1 || true); [[ "$out" == *"A.swift"* && "$out" == *"B.txt"* ]] && ok "GitHub token and URL credentials caught" || bad "token/url: $out"

# 6. PII: email, IPv4, phone, home path → exit 1, category PII
R=$(mkrepo pii); cd "$R"
printf 'mail me at jane.doe@corp.example\nhost 10.0.0.12\ncall +31 6 1234 5678\nsee /Users/jane/Desktop\n' > notes.md; git add . && git commit -q -m k
out=$("$SCAN" "$R" 2>&1 || true)
c=$(grep -c 'PII' <<<"$out" || true); [ "$c" -ge 4 ] && ok "email, IPv4, phone and home path caught as PII ($c hits)" || bad "PII hits=$c: $out"

# 7. allowlist: a matching regex silences that hit only
printf '# allowed\njane\\.doe@corp\\.example\n' > .releasescan-allow; git add . && git commit -q -m allow
out=$("$SCAN" "$R" 2>&1 || true)
[[ "$out" != *"jane.doe@corp.example"* && "$out" == *"10.0.0.12"* ]] && ok "allowlist silences only the listed hit" || bad "allowlist: $out"

# 8. untracked files are not scanned; binary files are skipped
R=$(mkrepo untracked); cd "$R"; echo 'AKIAIOSFODNN7EXAMPLE' > loose.txt
"$SCAN" "$R" >/dev/null 2>&1 && ok "untracked file ignored" || bad "untracked file was scanned"
head -c 400 /dev/urandom > blob.bin; git add blob.bin && git commit -q -m b
"$SCAN" "$R" >/dev/null 2>&1 && ok "binary file skipped" || bad "binary file broke the scan"

# 9. dates and versions are not phone numbers or IPs
R=$(mkrepo dates); cd "$R"; printf 'released 2026-09-28 20:58:09\nswift-tools-version: 5.9\nmacOS 14.0\n' > a.md; git add . && git commit -q -m d
"$SCAN" "$R" >/dev/null 2>&1 && ok "dates and versions not flagged" || bad "dates/versions flagged: $("$SCAN" "$R" 2>&1 || true)"

# 10. Apple signing material: .p8/.p12/.mobileprovision files, AuthKey references,
#     App Store Connect key id / issuer assignments, exported Sparkle private key
R=$(mkrepo apple); cd "$R"
printf -- '-----BEGIN PRIVATE KEY-----\nMIGT\n-----END PRIVATE KEY-----\n' > AuthKey_AB12CD34EF.p8
printf 'cert' > dist.p12; printf 'prof' > app.mobileprovision
printf 'KEY="$HOME/.secrets/AuthKey_AB12CD34EF.p8"\nKEY_ID="AB12CD34EF"\nISSUER="3eb5d7ab-66f4-448f-b174-165413a98055"\n' > notarize.sh
printf 'SUPrivateEDKey: 3rlBpsPkdQvv7bF0RSVFq7lZPhnKh4KngMIRVSOSTDo=\n' > sparkle.txt
git add . && git commit -q -m apple
out=$("$SCAN" "$R" 2>&1 || true)
for want in 'AuthKey_AB12CD34EF.p8' 'dist.p12' 'app.mobileprovision' 'KEY_ID' 'ISSUER' 'sparkle.txt'; do
  [[ "$out" == *"$want"* ]] && ok "apple: $want caught" || bad "apple: $want missed: $out"
done
grep -q 'APPLE' <<<"$out" && ok "apple hits carry the APPLE category" || bad "no APPLE category in: $out"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
