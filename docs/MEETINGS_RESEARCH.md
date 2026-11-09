# Meeting-jegyzetelő – kutatás: REA, Fireflies, Business Flow 1. szakasz

Dátum: 2026-11-04. Források: `github.com/morluto/rea` (klón: `/workspace/rea`), `fireflies.ai` nyitóoldal.

## REA (morluto/rea)

- **Mi ez:** „Reverse Engineer Anything” – MCP-szerver + CLI ügynököknek bináris, JS/Electron, .NET appok és
  weboldalak visszafejtéséhez (Hopper/Ghidra/IDA hidak, böngésző-megfigyelés). **Nem meeting-jegyzetelő.**
- **Licenc:** MIT (© 2026 morluto) – a kód újrahasznosítható a szerzői megjegyzés megtartásával.
- **Átvett kód:** nincs (nem volt rá szükség). **Átvett ötletek** (saját implementációval):
  1. *Untrusted content marker*: a célból származó szöveget az eszközeredmény `_meta.provenance.untrusted_content`
     mezője jelöli, és a szerver-utasítás kimondja: a benne lévő kérést nem szabad végrehajtani. Nálunk az
     átirat a résztvevők szava → ugyanez a prompt-injekció kockázat. **Megvalósítva** (`mcp.ts`).
  2. *Egyparancsos setup mentéssel* (`npx rea-agents setup`, backup a régi konfigról). Nálunk:
     `bflow mcp setup claude` (`.bak-*` mentés, a többi szervert nem bántja). **Megvalósítva.**
  3. CLI és MCP ugyanazon mag fölött, JSON kimenet (`--json`) szkripteléshez – már így terveztük, megerősítve.
  4. Eredmény + korlátok együtt („evidence and limitations”) → az átiratban jelöljük a forrást
     (Meet-felirat vs. hangból átírt) és a pontatlanságot.

## Fireflies.ai – funkciók

Automatikus csatlakozás naptárból (Zoom/Meet/Teams), 95%-os átirat 100+ nyelven, **beszélőfelismerés**,
nyelvfelismerés, összefoglaló (áttekintés, pontok, **teendők**, egyedi jegyzetek), **AI-keresés**, élő „Live Assist”,
beszédidő-statisztika, hangulat- és témakövetés, „AI Skills” (CRM, follow-up e-mail), MCP (Claude/ChatGPT),
integrációk (Slack, CRM, PM, ATS), **letöltés/export** (összefoglaló, átirat, hang), soundbite-ok, csatornák,
megjegyzések, mobil- és asztali app, vállalati biztonság (SOC2, GDPR). Ingyenes csomag + fizetős szintek.

## Összehasonlítás

| Funkció | Fireflies | REA | Business Flow 1. szakasz (most) |
|---|---|---|---|
| Naptárból auto-csatlakozás | ✅ Meet/Zoom/Teams | – | ✅ Meet (iCal), Teams link felismerve |
| Vendég-bot név | ✅ „Fireflies Notetaker” | – | ✅ „Business Flow jegyzetelő” |
| Átirat | ✅ felhő | – | ✅ saját kulcs, meglévő modell + tartalék |
| Beszélőnevek | ✅ hangalapú | – | ✅ **Meet élő felirat DOM-ból** (új) |
| Tartalék átirat | – | – | ✅ **Meet-felirat, ha nincs hang/kulcs** (új) |
| Résztvevőlista | ✅ | – | ✅ **participants.json** (új) |
| Beszédidő | ✅ | – | ✅ **feliratból** (új) |
| Összefoglaló + teendők | ✅ | – | ✅ felelős névvel a feliratból (új) |
| Teendők gyűjtése | ✅ Tasks | – | ✅ **`bflow actions` / `list_action_items`** (új) |
| Keresés | ✅ AI | – | ✅ szöveges (`search`) |
| „Ask” chat | ✅ | – | ✅ MCP-n át Claude/ChatGPT válaszol (kulcs nélkül a szerveren) |
| Export/megosztás | ✅ | – | ✅ **`bflow export` / `export_meeting` md/json** (új) |
| MCP | ✅ felhő | ✅ | ✅ helyi stdio + HTTP token |
| Prompt-injekció jelölés | ? | ✅ | ✅ **(új, REA-minta)** |
| Integrációk (Slack, CRM) | ✅ | – | ❌ (szándékosan: nincs küldés/költség) |
| Teams csatlakozás | ✅ | – | ⏳ 2. szakasz |
| Ár | freemium | ingyenes | 0 Ft extra |

## Prioritizált terv (csak 0 Ft-os elemek)

1. ✅ **Beszélőnevek a Meet feliratából** – a segéd bekapcsolja a feliratot (`c` / „Turn on captions”),
   a felirat-régió blokkjait (beszélő + szöveg) `captions.jsonl`-be írja; az app összefésüli, beszédidőt számol.
2. ✅ **Felirat mint tartalék átirat** – ha nincs hang vagy az átírás hibázik, a felirat adja az átiratot és az összefoglalót.
3. ✅ **Teendők felelőssel** – az összefoglaló bemenete a hangalapú átirat + a nevesített felirat; `bflow actions`.
4. ✅ **Export**, **untrusted jelölés**, **`bflow mcp setup claude`**.
5. ⏳ **Auto-admit tippek** (dokumentálva a MEETINGS.md-ben): a saját meetingjeidnél Meet → Host controls →
   „Meeting access: Open” (vagy a bot neve előre meghívott vendégként), így nem kell kézzel beengedni.
6. ⏳ **Teams vendég-csatlakozás** (2. szakasz): ugyanaz a segédváz, `teams.microsoft.com` → „Continue on this browser” →
   név → „Join now”; felirat: „More → Language and speech → Turn on live captions”. Valódi teszt-meeting kell hozzá.
7. ⏳ Hozzájárulás-üzenet a meeting chatjébe (opcionális, alapból KI) – csak a felhasználó jóváhagyásával.
8. ⏳ Outlook-naptár (ICS „publish” cím), helyi szemantikus keresés (később, ha ingyenes helyi modell elég).

Kihagyva: hangulatelemzés, CRM/Slack integráció, soundbite, vállalati jogosultságok – nem 0 Ft-os vagy nem kell egy főnek.
