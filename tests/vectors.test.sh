#!/bin/sh
# The generator's verdict on the shared assignment vectors (tests/vectors/assignments.txt);
# tests/kcm.test.mjs checks the WebUI's verdict on the same file.
. "$ROOT/tests/lib.sh"

grep -v '^#' "$ROOT/tests/vectors/assignments.txt" > "$WORK/vectors"
while IFS='|' read -r verdict assignment; do
    generator_agrees() {
        write_config "$WORK/one" "$assignment"
        if run_awk busybox -f "$ROOT/src/patch.awk" "$WORK/one" "$FIXTURES/key2-base.kcm" >/dev/null 2>&1
        then got=accept; else got=reject; fi
        [ "$got" = "$verdict" ] || { echo "generator: $got"; return 1; }
    }
    check "generator: $verdict $assignment" generator_agrees
done < "$WORK/vectors"

finish
