#!/usr/bin/env bash
# Tests for the evidence library — specifically the transfer law (SPEC/70 §6).
#
# The fixture records live in a temporary store, never in evidence/. A fabricated observation is
# indistinguishable from a real one once it is in the real store, and an evidence store whose
# contents were not actually observed is worse than an empty one.
set -uo pipefail

cd "$(dirname "$0")/../.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; pkill -f "php -S 127.0.0.1:8099" 2>/dev/null || true' EXIT

mkdir -p "$TMP/sora" "$TMP/provider"
cat > "$TMP/sora/fixtures.jsonl" <<'EOF'
{"observation":"Restating the gait phase at the cut preserved stride continuity","confidence_ppm":800000,"conditions":"5s continuation, single subject","applicable_provider":"sora","transferability":"PROVIDER_SPECIFIC","failure_cases":["failed when two subjects shared the frame"],"recorded_at_ms":1,"origin":"U"}
{"observation":"Camera speed stated as a distance held better than a movement name","confidence_ppm":700000,"conditions":"lateral tracking shots","applicable_provider":"sora","transferability":"CROSS_PROVIDER_OBSERVED","failure_cases":[],"recorded_at_ms":2,"origin":"U"}
EOF
cat > "$TMP/provider/fixtures.jsonl" <<'EOF'
{"observation":"Reference weight above 900000ppm over-constrained the pose","confidence_ppm":600000,"conditions":"identity reference on a moving subject","applicable_provider":"seedance","transferability":"PROVIDER_SPECIFIC","failure_cases":[],"recorded_at_ms":3,"origin":"M"}
EOF
printf 'this is not json\n' > "$TMP/sora/broken.jsonl"

failures=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1${2:+$'\n''        '$2}"; failures=$((failures + 1)); }

B1_EVIDENCE_ROOT="$TMP" php -S 127.0.0.1:8099 surfaces/php/evidence.php >/dev/null 2>&1 &
sleep 2

get() { curl -s --noproxy '*' "http://127.0.0.1:8099$1"; }
jq_() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

echo "evidence library"

# Unfiltered: every record keeps its stated transferability.
raw=$(get "/api/evidence")
if [ -z "$raw" ]; then
  bad "server responded"
else
  ok "server responded"
  n=$(echo "$raw" | jq_ "len(d['records'])")
  [ "$n" -eq 4 ] && ok "all records loaded, including the malformed one" \
                 || bad "loaded $n records, expected 4"

  malformed=$(echo "$raw" | jq_ "sum(1 for r in d['records'] if r.get('malformed'))")
  [ "$malformed" -eq 1 ] && ok "a malformed record is surfaced, not silently dropped" \
                         || bad "malformed count was $malformed"

  stated=$(echo "$raw" | jq_ "[r['effective_transferability'] for r in d['records'] if r.get('applicable_provider')=='seedance'][0]")
  [ "$stated" = "PROVIDER_SPECIFIC" ] && ok "an unfiltered record keeps its stated transferability" \
                                      || bad "got $stated"
fi

# The transfer law: querying for a provider a record was not observed on.
filtered=$(get "/api/evidence?provider=seedance")
sora_effective=$(echo "$filtered" | jq_ "[r['effective_transferability'] for r in d['records'] if r.get('applicable_provider')=='sora']")
case "$sora_effective" in
  "['HYPOTHESIS_ONLY', 'HYPOTHESIS_ONLY']")
    ok "sora records are downgraded to HYPOTHESIS_ONLY when queried for seedance" ;;
  *) bad "downgrade did not happen" "$sora_effective" ;;
esac

conf=$(echo "$filtered" | jq_ "[r['confidence_ppm'] for r in d['records'] if r.get('applicable_provider')=='sora' and r['transferability']=='PROVIDER_SPECIFIC'][0]")
[ "$conf" -eq 0 ] && ok "confidence is stripped on downgrade" \
                  || bad "confidence survived the downgrade as $conf"

own=$(echo "$filtered" | jq_ "[r['effective_transferability'] for r in d['records'] if r.get('applicable_provider')=='seedance'][0]")
[ "$own" = "PROVIDER_SPECIFIC" ] && ok "a record observed on the target provider is not downgraded" \
                                 || bad "got $own"

reason=$(echo "$filtered" | jq_ "[r.get('downgrade_reason','') for r in d['records'] if r.get('applicable_provider')=='sora'][0]")
case "$reason" in
  *"hypothesis to test, never as a finding"*) ok "the downgrade states why" ;;
  *) bad "downgrade reason was unhelpful" "$reason" ;;
esac

# Cross-provider observation is a stronger lead but still not a finding for an untested provider.
cross=$(echo "$filtered" | jq_ "[r['effective_transferability'] for r in d['records'] if r['transferability']=='CROSS_PROVIDER_OBSERVED'][0]")
[ "$cross" = "HYPOTHESIS_ONLY" ] && ok "cross-provider evidence is still a hypothesis for an untested provider" \
                                 || bad "got $cross"

echo
if [ "$failures" -eq 0 ]; then echo "PASSED: 0 failures"; else echo "FAILED: $failures failure(s)"; fi
exit $((failures > 0))
