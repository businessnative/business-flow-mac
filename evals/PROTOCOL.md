# Business Flow (desktop) – eval protokoll

Futtatás a Macen: `scripts/eval.sh [--live] [--gui]` → `evals/results/<dátum>.md` pontozólap.
Alapból csak költségmentes, fej nélküli rétegek futnak; `--live` valós API-hívásokat (kreditet) használ,
`--gui` csak feloldott képernyőnél, legfeljebb 2 kísérlettel, zárolt képernyőnél kihagyva.

| # | Terület | Réteg | Ellenőrzés |
|---|---------|-------|------------|
| 1 | Késleltetés szakaszonként | live | `--eval llm` BF_REASONING_EFFORT=off vs low (medián ms), `--eval audio` medián ms; GUI E2E: ms_transcribe/format/insert |
| 2 | WER / minőség (magyar TTS készlet) | live | `--eval audio`: átlagos WER, zaj-hallucináció; `--eval llm`: pontszám |
| 3 | Indítás/leállítás Fn, Fn+Space, beragadás | unit+selftest | HotkeyEngine tesztek (fnSpaceHandsFreeCycles, lostFnRelease…), 40×start/stop, 40×cancel, őr/időtúllépés |
| 4 | Csendes alapértelmezés, hang kapcsoló, hangerő | unit+selftest | sounds=false alap, hangerő clamp 0…1, kapcsoló → jelzés |
| 5 | Nincs Kulcskarika-ablak | static+cli | SecItem csak a régi-elem áthozatalban, UI letiltva (`kSecUseAuthenticationUIFail`); `--has-key` időkorláton belül ablak nélkül |
| 6 | Szolgáltatóváltás, kulcsteszt, tartalék | unit+live | ProvidersTests (router fallback); `--test-key openai/anthropic/gemini` |
| 7 | Elfogyott kredit üzenet | unit | 402 / 429 credit_balance → .quota, üzenet „kredit” |
| 8 | Hosszú felvétel, csend, nincs jel, eszközváltás | unit+selftest | tooLarge, csend → „Nem hallottam semmit”, mikrofonváltás selftest, AVAudioEngineConfigurationChange |
| 9 | Beillesztés appokba, vágólap visszaállítás | gui | E2E TextEdit (+ Notes/böngésző kézi), vágólap visszaáll |
| 10 | Ékezetek, speciális karakterek | unit | accentsSurviveTextPipeline, TextRules tesztek |
| 11 | Több monitor / fókuszváltás | selftest+gui | cél-app újraaktiválás beillesztés előtt; E2E fókusz-ellenőrzés |
| 12 | Alvás/ébredés | selftest | alvás felvétel közben → megszakítás; ébredés után indítható |
| 13 | Offline / hálózati hiba | unit+selftest | URLError → .network; selftest „hálózati hiba → hibaüzenet” |
| 14 | Beállítások megőrzése újraindítás után | unit | settingsPersistAcrossRestart |

Kilépési feltétel: unit 100%, selftest 0 hiba, static OK, live WER ≤ előző érték, text pontszám ≥ előző.
