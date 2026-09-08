#!/usr/bin/env bash
# Tests for the media analyzer, using synthetic frame sequences generated here.
#
# Synthesizing the input rather than shipping a video file keeps the test hermetic and makes the
# expected behaviour explicit: we know exactly what moved between frames, so we know what the
# metrics should say about it.
set -uo pipefail

cd "$(dirname "$0")"
BIN=build/b1media
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

failures=0
ok()   { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1"; failures=$((failures + 1)); }

# Writes a PPM sequence: a bright block at x=$offset+i*$step on a fixed gradient.
make_seq() {
  local out=$1 frames=$2 offset=$3 step=$4
  python3 - "$out" "$frames" "$offset" "$step" <<'PY'
import sys
out, frames, offset, step = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
W, H = 160, 90
with open(out, "wb") as f:
    for n in range(frames):
        f.write(b"P6\n%d %d\n255\n" % (W, H))
        bx = offset + n * step
        row = bytearray()
        for y in range(H):
            base = y * 200 // H
            for x in range(W):
                v = 250 if (bx <= x < bx + 20 and H // 3 < y < 2 * H // 3) else base
                row += bytes((v, v, v))
        f.write(bytes(row))
PY
}

field() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }

echo "media analyzer"

# 1. A static sequence: no motion, maximum stability.
make_seq "$TMP/static.ppm" 6 20 0
static_json=$($BIN "$TMP/static.ppm" 2>/dev/null)
if [ -z "$static_json" ]; then
  bad "static sequence analyzed"
else
  ok "static sequence analyzed"
  energy=$(echo "$static_json" | field motion_energy_mean_mu)
  stab=$(echo "$static_json" | field temporal_stability_mu)
  [ "$energy" -eq 0 ] && ok "static sequence has zero motion energy" || bad "static motion energy was $energy, expected 0"
  [ "$stab" -eq 1000 ] && ok "static sequence is maximally stable" || bad "static stability was $stab, expected 1000"
fi

# 2. A moving sequence: motion registers, and stability drops below static.
make_seq "$TMP/moving.ppm" 6 20 12
moving_json=$($BIN "$TMP/moving.ppm" 2>/dev/null)
if [ -z "$moving_json" ]; then
  bad "moving sequence analyzed"
else
  ok "moving sequence analyzed"
  m_energy=$(echo "$moving_json" | field motion_energy_mean_mu)
  m_stab=$(echo "$moving_json" | field temporal_stability_mu)
  [ "$m_energy" -gt 0 ] && ok "motion registers as energy ($m_energy)" || bad "moving sequence reported zero motion"
  [ "$m_stab" -lt 1000 ] && ok "motion reduces temporal stability ($m_stab)" || bad "moving stability was $m_stab"
fi

# 3. Frame count and signatures.
count=$(echo "$moving_json" | field frame_count)
[ "$count" -eq 6 ] && ok "all six frames read" || bad "frame_count was $count, expected 6"

first=$(echo "$moving_json" | field first_frame_signature)
last=$(echo "$moving_json" | field final_frame_signature)
[ ${#first} -eq 64 ] && ok "first frame signature is a 64-hex digest" || bad "first signature malformed: $first"
[ "$first" != "$last" ] && ok "first and final signatures differ across a moving take" || bad "signatures identical despite motion"

# 4. Every metric is labelled as a proxy — a proxy that loses its label becomes a claim.
basis=$(echo "$moving_json" | field measurement_basis)
case "$basis" in
  PROXY*) ok "metrics are labelled PROXY" ;;
  *)      bad "measurement_basis did not identify the metrics as proxies: $basis" ;;
esac

# 5. A spliced sequence: two unrelated segments joined, which should flag a discontinuity.
make_seq "$TMP/segA.ppm" 4 10 2
make_seq "$TMP/segB.ppm" 4 130 2
cat "$TMP/segA.ppm" "$TMP/segB.ppm" > "$TMP/spliced.ppm"
spliced_json=$($BIN "$TMP/spliced.ppm" 2>/dev/null)
flag=$(echo "$spliced_json" | field discontinuity_candidate)
idx=$(echo "$spliced_json" | field discontinuity_frame_index)
if [ "$flag" = "True" ]; then
  ok "splice flagged as a discontinuity candidate (frame $idx)"
  [ "$idx" -eq 4 ] && ok "discontinuity located at the splice point" || bad "located at frame $idx, expected 4"
else
  bad "splice was not flagged"
fi

echo
if [ "$failures" -eq 0 ]; then echo "PASSED: 0 failures"; else echo "FAILED: $failures failure(s)"; fi
exit $((failures > 0))
