# Biztonság / Security

- **Nincs titok a repóban.** Nincs beépített API-kulcs, közös kredit, proxy- vagy relészerver, analitika, telemetria, hibakövető (Sentry stb.) vagy frissítési csatorna. Az app kizárólag a **te** kulcsoddal, közvetlenül hívja a választott szolgáltatót (`api.openai.com`, `api.anthropic.com`, `generativelanguage.googleapis.com`).
- **macOS:** a kulcsok a saját Maceden, géphez kötött titkosított fájlban vannak (`~/Library/Application Support/Business Flow/`). Nem kerülnek naplóba, repóba, felhőbe.
- **iOS:** a kulcsok csak az eszköz Kulcskarikájában vannak (`expo-secure-store`).
- Soha ne commitold: `.env`, aláíró tanúsítvány (`.p12`, `.p8`, `.cer`), provisioning profile, kulcskarika, naplók, hangfelvételek, eval-kimenetek, naptár (iCal) titkos URL-ek.
- A bundle ID egy semleges helyőrző (`com.example.businessflow`) – cseréld a sajátodra: `scripts/set-bundle-id.sh com.sajatnev.businessflow`.

## Sebezhetőség bejelentése
Kérjük, ne nyiss nyilvános issue-t: használd a GitHub **Security → Report a vulnerability** (privát bejelentés) funkcióját ebben a repóban.
