#!/bin/bash
# Eval protokoll futtató (lásd evals/PROTOCOL.md). Kulcsot soha nem ír ki.
set -uo pipefail
cd "$(dirname "$0")/.."
LIVE=0; GUI=0; for a in "$@"; do [ "$a" = --live ] && LIVE=1; [ "$a" = --gui ] && GUI=1; done
B="${BF_BIN:-/Applications/Business Flow.app/Contents/MacOS/BNFlow}"
OUT="evals/results/$(date +%Y%m%d-%H%M).md"; mkdir -p evals/results
row() { echo "| $1 | $2 | $3 |" | tee -a "$OUT"; }
run_to() { local t=$1; shift; ( "$@" > /tmp/bf-eval-out 2>&1 ) & local p=$!; for _ in $(seq 1 $t); do kill -0 $p 2>/dev/null || break; sleep 1; done; kill $p 2>/dev/null; wait $p; }
echo "# Eval $(date '+%F %R') ($(git rev-parse --short HEAD))" > "$OUT"; echo "| réteg | eredmény | részlet |" >> "$OUT"; echo "|---|---|---|" >> "$OUT"

U=$(scripts/test.sh 2>&1 | grep -E "Test run with" | tail -1)
[[ "$U" == *passed* ]] && row unit PASS "$U" || row unit FAIL "${U:-build/test hiba}"

run_to 300 "$B" --self-test; S=$(grep "ÖSSZESEN" /tmp/bf-eval-out | tail -1)
F=$(grep -E "^FAIL" /tmp/bf-eval-out | cut -c1-90 | head -5 | tr '\n' ';')
[[ "$S" == *" 0 hibás"* ]] && row selftest PASS "$S" || row selftest FAIL "${S:-nem futott le} $F"

# Kulcskarika: SecItem csak a régi-elem áthozatalban, UI-mentesen
N=$(grep -rl "SecItem" Sources | grep -v System.swift | wc -l | tr -d ' ')
grep -q kSecUseAuthenticationUIFail Sources/BNFlow/System.swift && [ "$N" = 0 ] && row static-keychain PASS "SecItem csak System.swift legacy" || row static-keychain FAIL "$N fájl"
# Ablak nélküli kulcsolvasás: ha a Kulcskarika kérdezne, a --has-key blokkolna (időkorlát) — a kimenetben csak hossz szerepel.
T0=$(date +%s); run_to 10 "$B" --has-key; T1=$(date +%s); NK=$(grep -c "van kulcs" /tmp/bf-eval-out)
[ $((T1-T0)) -lt 8 ] && [ "$NK" -ge 1 ] && row no-prompt PASS "--has-key $((T1-T0)) s, $NK szolgáltató kulcsa olvasható" || row no-prompt FAIL "blokkolt vagy nincs kulcs ($((T1-T0)) s)"

if [ $LIVE = 1 ]; then
  for p in openai anthropic gemini; do run_to 30 "$B" --test-key $p; row "key-$p" INFO "$(tail -1 /tmp/bf-eval-out | cut -c1-80)"; done
  for e in off low; do BF_REASONING_EFFORT=$e run_to 600 "$B" --eval llm; row "llm-effort-$e" INFO "$(grep "^→" /tmp/bf-eval-out | tail -1)"; done
  run_to 600 "$B" --eval audio; row audio INFO "$(grep '→ audio' /tmp/bf-eval-out | tail -1)"
fi

if [ $GUI = 1 ]; then
  LOCKED=$(ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes' && echo 1 || echo 0)
  if [ "$LOCKED" != 0 ]; then row gui SKIP "képernyő zárolva"; else
    for i in 1 2; do
      osascript -e 'quit app "Business Flow"'; sleep 2; rm -f /tmp/bf-e2e.json
      open -a TextEdit /tmp/bf-e2e-doc.txt; osascript -e 'tell application "TextEdit" to activate'; sleep 2
      open -n "/Applications/Business Flow.app" --args --e2e /tmp/bf-e2e.json
      for _ in $(seq 1 80); do python3 -c "import json,sys;d=json.load(open('/tmp/bf-e2e.json'));sys.exit(0 if 'cases' in d or 'blocked' in d else 1)" 2>/dev/null && break; sleep 5; done
      R=$(python3 -c "
import json;d=json.load(open('/tmp/bf-e2e.json'))
if d.get('blocked'): print('BLOCKED');raise SystemExit
c=d['cases'];ok=sum(1 for x in c if x.get('ok'));import statistics as s
m=lambda k:int(s.median([x[k] for x in c if isinstance(x.get(k),(int,float))] or [0]))
print(f'{ok}/{len(c)} ok, medián tr {m(\"ms_transcribe\")} fmt {m(\"ms_format\")} ins {m(\"ms_insert\")} total {m(\"ms_total\")} ms')" 2>/dev/null)
      [ "$R" != BLOCKED ] && [ -n "$R" ] && { row gui INFO "$R"; break; }; [ $i = 2 ] && row gui SKIP "fókusz/zárolás miatt blokkolva"
    done
    open -a "Business Flow}"
  fi
fi
echo "pontozólap: $OUT"
