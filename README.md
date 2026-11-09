# Business Flow (macOS)

Magyar/angol diktálóapp macOS-re (Wispr Flow-szerű): tartsd lenyomva az `fn`-t, beszélj, és a tisztított szöveg bekerül a kurzorhoz – bármelyik appban.
Natív Swift (SwiftUI + AppKit), SwiftPM-mel épül; Xcode nem kell, a Command Line Tools elég.

> **Közösségi kiadás – BYOK (saját kulccsal).** Nincs beépített API-kulcs, közös kredit, köztes szerver, analitika vagy telemetria.
> Mindenki a **saját** OpenAI / Gemini (és opcionálisan Anthropic) kulcsát adja meg; az app közvetlenül a szolgáltatót hívja. Lásd `SECURITY.md`.

További kiadások: [iPhone](https://github.com/businessnative/business-flow-ios) · [Windows + macOS asztali](https://github.com/businessnative/business-flow-windows).

## Telepítés AI-ügynökkel (Claude Code, Cursor, Codex …)

Add oda ezt a repót az AI-ügynöködnek ezzel a kéréssel: *„Telepítsd a Business Flow Mac appot a README »Telepítés AI-ügynökkel« része szerint.”* Az ügynök lépései:

1. **Előfeltételek:** Apple Silicon Mac, macOS 14+. `xcode-select -p` – ha hiányzik: `xcode-select --install`. Ellenőrzés: `swift --version` (5.9+).
2. **Klónozás:** `git clone https://github.com/businessnative/business-flow-mac.git ~/business-flow-mac && cd ~/business-flow-mac`
3. **Saját bundle ID (az első indítás előtt!):** `scripts/set-bundle-id.sh com.<sajatnev>.businessflow` – a semleges `com.example.businessflow` helyőrzőt cseréli mindenhol (Info.plist, aláírás, napló-alrendszer, kulcstároló). Apple fejlesztői fiók / Team ID nem kell.
4. **Tesztek:** `scripts/test.sh`
5. **Építés:** `scripts/build-app.sh` → `dist/Business Flow.app` + `dist/Business-Flow-<verzió>.dmg` (helyi ad-hoc aláírás).
6. **Telepítés:** `ditto "dist/Business Flow.app" "/Applications/Business Flow.app"`, majd első indításkor jobb klikk → **Megnyitás**.
7. **Engedélyek** (a felhasználónak kell kattintania): Mikrofon, Kisegítő hozzáférés, Bemenetfigyelés – lásd lent. A 🌐/fn billentyűt állítsd „Ne csináljon semmit”-re (Rendszerbeállítások → Billentyűzet).
8. **Saját API-kulcs:** Hub → Beállítások → API-kulcs → illeszd be (vagy válaszd ki a saját `.env` fájlodat). Parancssorból (az értéket nem írja ki):
   `"/Applications/Business Flow.app/Contents/MacOS/BNFlow" --import-env /utvonal/a/sajat/.env --key OPENAI_API_KEY`
   Kulcs: [OpenAI](https://platform.openai.com/api-keys) · [Gemini](https://aistudio.google.com/apikey) · [Anthropic](https://console.anthropic.com/settings/keys). Minta: `.env.example`.
9. **Ellenőrzés:** Hub → Beállítások → API-kulcs → **Kulcs tesztelése**, majd egy próbadiktálás bármelyik szövegmezőben.
10. *(Opcionális)* Meeting-jegyzetelő: `cd meetings && npm install && npm run build`, részletek: `docs/MEETINGS.md`.

> Ügynököknek: soha ne commitolj `.env`-et, kulcsot, aláíró tanúsítványt vagy naplót. A kulcsot a felhasználó illessze be.

## Építés kézzel

```bash
scripts/test.sh            # egységtesztek (BNFlowCore, Swift Testing — Xcode nélkül is fut)
scripts/build-app.sh       # → dist/Business Flow.app + dist/Business-Flow-<verzió>.dmg
swift build && .build/debug/BNFlow --self-test --passes 2   # teljes felületi önteszt
```

Opcionális stabil aláírás (hogy újraépítés után megmaradjanak az engedélyek): hozz létre egy önaláírt „Business Flow Local Signing” kódaláíró tanúsítványt a `~/Library/Keychains/business-flow-signing.keychain-db` kulcskarikában – a `scripts/build-app.sh` automatikusan használja, különben ad-hoc aláír.

## Költségek és követelmények

Az app ingyenes és nyílt forrású (MIT). **Fizetni csak a saját AI-szolgáltatói fiókodban** fizetsz, használat szerint – közvetlenül az OpenAI-nak / Google-nak / Anthropicnak. Nincs előfizetés, nincs közvetítő, a fejlesztő semmit nem lát és nem számláz.

### Milyen szolgáltatást használ (a kódban ténylegesen bekötve)

| Feladat | Szolgáltató / modell (alapértelmezett → tartalék) | Kötelező? |
|---|---|---|
| Beszéd → szöveg (diktálás) | **OpenAI** `gpt-transcribe` → `gpt-4o-transcribe` (Macen `gpt-4o-mini-transcribe` is választható), **vagy Google Gemini** `gemini-3.5-flash-lite` | **Igen, legalább egy:** OpenAI- vagy Gemini-kulcs. Helyi/offline beszédfelismerés nincs. |
| Szövegtisztítás („Okos formázás”, parancs mód, polírozás) | OpenAI `gpt-5.6-luna` → `gpt-4.1-mini`, **vagy** Claude `claude-haiku-5-5` (Sonnet 5.5 választható), **vagy** Gemini `gemini-3.5-flash-lite` | Nem. Kikapcsolható; ilyenkor a beépített **helyi magyar szövegmotor** dolgozik (ingyenes, offline). Rövid, tiszta mondatoknál alapból is kimarad az LLM-hívás. |
| Meeting-jegyzetelő (csak Mac, opcionális) | A fenti átíró + szövegmodell (átirat + összefoglaló). A Google Meetbe vendégként, külön Chrome-profillal csatlakozik. | Nem. Kell hozzá: Node.js + Google Chrome; díj = az átírt percek. |
| Hívás-jegyzetek (csak iOS, opcionális) | OpenAI `gpt-4o-transcribe-diarize` (beszélők szétválasztása), összefoglaló a választott szövegmodellel | Nem. |

> Az Anthropic Claude-nak nincs beszéd→szöveg API-ja, ezért **csak Claude-kulccsal az app nem tud diktálni** – mellé kell OpenAI- vagy Gemini-kulcs.

### Árak (hivatalos árlisták, ellenőrizve: 2026. november 9.)

| Modell | Ár |
|---|---|
| OpenAI `gpt-transcribe` | $0.0045 / hangperc |
| OpenAI `gpt-4o-mini-transcribe` | ~$0.003 / perc |
| OpenAI `gpt-4o-transcribe`, `gpt-4o-transcribe-diarize` | ~$0.006 / perc |
| OpenAI `gpt-5.6-luna` | $0.20 be / $1.20 ki / 1M token |
| OpenAI `gpt-4.1-mini` | $0.40 be / $1.60 ki / 1M token |
| Claude `claude-haiku-5-5` | $0.10 be / $0.50 ki / 1M token (≤100K tokenes promptnál) |
| Claude `claude-sonnet-5-5` | $2 be / $10 ki / 1M token |
| Gemini `gemini-3.5-flash-lite` (fizetős szint) | $0.30 be (szöveg/hang) / $2.50 ki / 1M token; a hang ~25 token/mp ≈ 1500 token/perc |
| Gemini ingyenes szint | $0, de sebességkorlátos, és a Google a bemenetet a termékei fejlesztésére használhatja |

Források: [OpenAI pricing](https://developers.openai.com/api/docs/pricing) · [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing) · [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing) · [Apple Developer Program](https://developer.apple.com/programs/)

### Becsült havi költség

Feltételezés: **30 perc diktálás naponta (≈900 perc/hó)** + **10 óra meeting havonta (600 perc)**, okos formázás bekapcsolva.

| Beállítás | Diktálás | Meetingek | **Összesen / hó** |
|---|---|---|---|
| Csak OpenAI (alapértelmezés: `gpt-transcribe` + `gpt-5.6-luna`) | ~$4.1 + ~$0.8 | ~$2.7 | **≈ $7–8** |
| OpenAI átírás + Claude Haiku 5.5 tisztítás | ~$4.1 + ~$0.4 | ~$2.7 | **≈ $7** |
| Csak Gemini (`gemini-3.5-flash-lite`, fizetős szint) | ~$1.1 + ~$1.4 | ~$0.8 | **≈ $3–4** |
| Gemini ingyenes szint | $0 | $0 | **$0** (korlátokkal, adatvédelmi kompromisszummal) |
| iOS hívás-jegyzetek (pl. 5 óra/hó, diarizálással) | | | + ≈ $1.8 |

A becslés közelítő (a magyar szöveg tokenszáma, a szótár/környezet hossza és a modellválasztás módosítja). Tipp: a szolgáltatói fiókban állíts be havi költségkeretet.

### Nem API jellegű követelmények

- **Mac app:** Apple Silicon Mac, macOS 14+, Xcode **Command Line Tools** (ingyenes; `xcode-select --install`). Apple fejlesztői fiók **nem kell** (helyi, ad-hoc aláírás). Meeting-jegyzetelőhöz: Node.js (pl. `brew install node`) és Google Chrome.
- **iPhone app:** Mac + **Xcode** (ingyenes) + iPhone iOS 17+, Node.js 24 (npm). Ingyenes Apple ID-val („Personal Team”) a saját telefonodra is telepíthető, de a telepítés **7 nap után lejár**, újra kell építeni (max. 3 eszköz). Tartós használathoz, TestFlighthoz vagy másoknak terjesztéshez **Apple Developer Program: 99 USD/év**. EAS felhős buildhez saját (ingyenes szintű) Expo-fiók.

## API-kulcsok és adatvédelem

- Átírás: OpenAI vagy Gemini; szövegtisztítás: OpenAI, Claude vagy Gemini – a Beállításokban választható, a modellek a Haladó fülön átírhatók.
- A kulcsok **csak a saját Maceden**, géphez kötött titkosított fájlban vannak (`~/Library/Application Support/Business Flow/keys.enc`, 0600). Nem kerülnek repóba, naplóba vagy felhőbe.
- A hang és a szöveg csak a te kulcsoddal, közvetlenül a választott szolgáltatóhoz megy. Előzmények helyben: `~/Library/Application Support/Business Flow/`.
- Ha a szolgáltatónál elfogy a keret vagy a kredit (pl. OpenAI `insufficient_quota`, Gemini `RESOURCE_EXHAUSTED`), az állapotsáv ezt írja ki: *„Elfogyott az átírás kerete. Nézd meg az OpenAI vagy a Gemini számlázását.”* – ilyenkor a saját [OpenAI](https://platform.openai.com/settings/organization/billing) vagy [Gemini](https://aistudio.google.com/usage) fiókodban kell keretet feltölteni.

## Funkciók

- **Lebegő Flow-sáv** (nem aktiváló NSPanel) a képernyő alján középen, mindig azon a monitoron, ahol az egér van. Üresjáratban kis pill; hoverre tooltip; felvételkor hullámforma; feldolgozáskor forgó gyűrű.
- **Push-to-talk:** tartsd lenyomva az `fn` billentyűt, beszélj, engedd el, és a szöveg bekerül a kurzorhoz (AX + vágólap mentés → ⌘V → vágólap visszaállítás).
- **Hands-free:** `fn + Space` (vagy PTT közben Space). Befejezés: újra a parancs, vagy a sáv ■ gombja; megszakítás: `Esc` / ✕.
- **Parancs mód:** `fn + ⌃` nyomva tartva. Kijelöléssel átírja a kijelölt szöveget („fordítsd angolra”, „tedd hivatalosabbá”), kijelölés nélkül megírja, amit kérsz.
- **Polírozás:** kijelölés + `⌃⌘P` → az alapértelmezett utasítással helyben átírja; „Kész · Változások” szó szintű különbség-nézettel. Beépített és saját utasítások.
- **Utolsó átirat beillesztése:** `⌃⌘V`.
- **Állítható billentyűparancsok**, egérgombokkal is (pl. 5. egérgomb nyomva tartva PTT).
- **Okos formázás** (töltelékszavak, önjavítás, listák, bekezdések), helyi töltelékszó-szűrés, hangparancsok („új sor”, „új bekezdés”).
- **Szótár** (helyes alak + téves alakok), **szövegrészletek** (kimondott kulcsmondat → teljes szöveg), **stílus** alkalmazás-típusonként (személyes üzenetek / munka / e-mail / egyéb).
- **Nyelvek:** magyar, angol, automatikus (hu+en, keverten is).
- **Hub ablak:** Kezdőlap (statisztikák, keresés, előzmények másolás/törlés/nyers átirat), Szótár, Szövegrészletek, Stílus, Polírozás, Beállítások (Általános, Nyelvek, Mikrofon, Billentyűk, Engedélyek, API-kulcs, Haladó).
- Média némítása diktálás közben, saját szintetizált hangjelzések, indítás bejelentkezéskor, sáv elrejtése üresjáratban, menüsor-ikon (BN pontmátrix-nyíl).
- Előzmények helyben: `~/Library/Application Support/Business Flow/history.json` (0600), megőrzési idő állítható.

### Újdonságok a 0.3.0-ban

- **Új név: Business Flow**, teljes businessnative-dark megjelenés (Geist betűk, Lucide ikonok, BN színek) a Flow-sávon, a Hubon, a beállításokban, a sáv saját menüjében és az első lépések listáján.
- **Gyorsabb:** TLS-előmelegítés a felvétel kezdetén (HEAD, legfeljebb 20 s-onként), és rövid, tiszta mondatoknál (≤ 12 szó, önjavítás/felsorolás/töltelékszó nélkül) kimarad az LLM-hívás – a helyi magyar motor azonnal beilleszt.
- **Suttogó mód:** zúgásszűrés (~80 Hz), halk/suttogott felvétel felismerése és erősítése (legfeljebb 40×), így a halk beszéd sem vész el csendként.
- **Magyar minőség:** kimondott írásjelek („kérdőjel”, „vessző”, „felkiáltójel”, „kettőspont”, „pontosvessző”).
- **Első lépések** a Kezdőlapon: API-kulcs, mikrofon, engedélyek, első diktálás – közvetlen „Beállítás” gombokkal.
- **Egérgomb-parancsok rögzítése** a Billentyűk fülön (pl. oldalsó 4./5. gomb).
- **Akadálymentesség:** a sáv STOP/✕ gombjai és az előzmények hover-gombjai VoiceOverrel is elérhetők, a nagybetűs címkéket normálisan olvassa fel.
- **Önteszt:** `BNFlow --self-test [kimenet.json] [--passes N]` – az app minden menüpontját és fülét AX-en keresztül végignyomkodja ideiglenes adatmappával, csonkolt hálózattal, mikrofonnal, Kulcskarikával és engedélyekkel (valódi beállításhoz, előzményhez, kulcshoz nem nyúl).

### Újdonságok a 0.2.0-ban

- **Helyi magyar szövegmotor** (LLM nélkül is, ~8 ms): önjavítás („nem, inkább…”, „ezt töröld”, „scratch that”), számozott listák kimondott sorszámokból, magyar vesszők (hogy/ami/aki/mert/de… + vonatkozó mellékmondat zárása), kérdőjel felismerése, „…” → „…” magyar idézőjel, ékezet-visszaállítás, kimondott e-mail/web-cím („info kukac pelda pont hu”), mozaikszavak (PR, API), mondatkezdő töltelék-kötőszó („szóval, ööö”) és a töltelékszó körüli felesleges vessző eltávolítása.
- **Toldalékbarát szótár:** „klikkapban” → „ClickUpban”, „Dorotyának” → „Dorottyának” (hosszú magánhangzó is).
- **Környezetfigyelés:** a kurzor előtti/utáni szöveghez igazítja a kis/nagybetűt és a záró írásjelet, a mezőben szereplő neveket helyesen írja, böngészőben az ablakcímből felismeri a Gmailt/Slacket stb. Jelszómezőből semmit nem olvas.
- **E-mail-elrendezés:** megszólítás, bekezdések, elköszönés + név külön sorban.
- **Biztonságos LLM-formázás:** időkorlát (alapból 8 s) után a helyi eredmény megy; prompt-injekció elleni keret; őr, ami elutasítja a túl sokat átíró választ.
- **Megbízható beillesztés:** ellenőrzi, hogy a szöveg tényleg bekerült-e; ha nem, AX-szel próbálja, végül a vágólapon hagyja („Vágólapra másolva – ⌘V”).
- **Szótár automatikus tanulása:** ha beillesztés után egy szót kijavítasz, felveszi a szótárba („Szótárba: X”).
- **Hangelőkészítés:** hangaktivitás-felismerés, csend levágása, halk (suttogott) felvétel erősítése, csend-hallucinációk („Köszönöm a figyelmet”) szűrése.
- **Utolsó felvétel újrapróbálása** a menüből, ha a feldolgozás hibára futott (csak memóriában tartjuk).
- **Értékelés:** `BNFlow --eval local|llm|audio|all --label X` → `eval/results/`.

Opcionális **meeting-jegyzetelő** (Google Meet): lásd `docs/MEETINGS.md`.

## Engedélyek (Rendszerbeállítások → Adatvédelem és biztonság)

| Engedély | Mire kell |
|---|---|
| Mikrofon | felvétel |
| Kisegítő hozzáférés | beillesztés, kijelölés olvasása |
| Bemenetfigyelés | globális billentyű-/egérparancsok (fn, egérgombok) |

A Hub **Beállítások → Engedélyek** oldala mutatja az állapotot és megnyitja a megfelelő panelt. A Bemenetfigyelés után indítsd újra az appot.

> Ad-hoc aláírás miatt **minden újraépítés után** előfordulhat, hogy a macOS az appot újnak tekinti: ilyenkor a Kisegítő hozzáférés / Bemenetfigyelés listából töröld (−) a régi Business Flow bejegyzést, és add hozzá újra a Business Flow-t.

## Felépítés

- `Sources/BNFlowCore` — tiszta, tesztelt logika: modellek, szövegfeldolgozás, WAV, .env-olvasó, OpenAI-kérések, billentyű-állapotgép, tárolók.
- `Sources/BNFlow` — app: sáv, Hub, menüsor, hangfelvétel (AVAudioEngine, 16 kHz mono), CGEventTap, beillesztés, Kulcskarika.
- `Resources/Fonts` — Geist (SIL OFL, `LICENSES/Geist-OFL.txt`).
- `docs/` — BN design tokenek.

