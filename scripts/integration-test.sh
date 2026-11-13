#!/bin/bash
# Converts the fixtures in the real sandbox using build/pixelwash and checks
# the results. Run via `make integration-test` after `make setup`.
set -u
cd "$(dirname "$0")/.."
PW="$PWD/build/pixelwash"
FIX="$PWD/Tests/PixelwashCoreTests/Fixtures"
WORK="$(mktemp -d /tmp/pixelwash-int.XXXXXX)"
fails=0

check() { # description, command...
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok      $what"; else echo "  FAILED  $what"; fails=$((fails + 1)); fi
}
pages() { grep -a -o '/Type /Page /' "$1" | wc -l | tr -d ' '; }

cp "$FIX"/sample.pdf "$FIX"/sample.docx "$FIX"/sample.png "$FIX"/empty.bin "$WORK"/
printf 'not a document \x00\x01\x02' > "$WORK/garbage.bin"
cd "$WORK"

echo "Sandbox:"
"$PW" doctor || fails=$((fails + 1))

echo "Conversions:"
"$PW" convert sample.pdf -o pdf-out.pdf >/dev/null 2>&1
check "PDF converts to 3 pages" test "$(pages pdf-out.pdf)" = 3
"$PW" convert sample.docx -o docx-out.pdf --no-ocr >/dev/null 2>&1
check "Word document converts (3+ pages)" test "$(pages docx-out.pdf)" -ge 3
"$PW" convert sample.png -o png-out.pdf --jpeg 0.7 >/dev/null 2>&1
check "PNG converts to 1 page" test "$(pages png-out.pdf)" = 1
"$PW" convert sample.pdf >/dev/null 2>&1 && "$PW" convert sample.pdf >/dev/null 2>&1
check "Default name is <name>-safe.pdf" test -f sample-safe.pdf
check "Existing output is never overwritten" test -f "sample-safe 2.pdf"
check "Output keeps no link to the original" sh -c '! grep -a -q "Pixelwash fixture" pdf-out.pdf'

echo "Failures:"
check "Empty file is rejected" sh -c "! '$PW' convert empty.bin"
check "Unknown file type is rejected" sh -c "! '$PW' convert garbage.bin"
check "Missing file is rejected" sh -c "! '$PW' convert nope.pdf"
check "Rejected files leave no output" sh -c '! ls -a | grep -E -q "empty-safe|garbage-safe|nope-safe|partial"'
check "Originals are unchanged" cmp -s sample.pdf "$FIX/sample.pdf"

echo "Work folder: $WORK"
[ "$fails" -eq 0 ] && echo "All integration checks passed." || { echo "$fails check(s) failed."; exit 1; }
