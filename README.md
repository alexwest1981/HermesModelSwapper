# HermesModelSwapper

En Omarchy-bar-widget som visar Hermes nuvarande standardmodell och byter den
med ett klick — via **Hermes egen switch-pipeline**, inte genom att skriva
config-nycklar för hand.

![widget i baren](bar.png)

## Vad den gör

- Visar robotikonen + aktuell modell i baren (högersektionen).
- Klick öppnar en dropdown med **det Hermes faktiskt har tillgång till**:
  - **Alias** — `model_aliases` / `model.aliases` från `~/.hermes/config.yaml`
  - **Per provider** — de providers och modeller Hermes eget inventory
    (`build_model_options_payload`) rapporterar, dvs. providers med giltiga
    credentials, med capabilities (`tänker`, `snabb`) i raden.
- En rad vars provider saknar nycklar (eller vars `key_env` inte finns i
  env/`.env`) markeras **före** klicket: *"providern gemini har inga giltiga
  nycklar hos Hermes"*. Hermes skulle ändå vägra — nu syns det i stället för att
  bli ett klick som bara ger fel.
- Aktuell modell markeras **AKTIV**. Högerklick = läs om katalogen.
- Knappen i rubriken hämtar en färsk katalog från Hermes på begäran; annars
  används en cachad katalog (lades i `~/.hermes/cache/hermes-model-widget.json`).

## Bytet

Ett val kör, i den ordningen:

1. **Urvalsskydden** för dyr modell/datapolicy
   (`model_selection_guards.combined_selection_warning`). Svarar de
   `confirm_required` visas Hermes eget meddelande i popupen med en
   **Bekräfta och byt**-knapp — inget ändras tyst.
2. **`model_switch.switch_model()`** — "core model-switching pipeline shared
   between CLI and gateway". Den löser alias, provider, `base_url`, `api_mode`
   och credentials åt dig. Två saker den gör som handskrivna nycklar inte gör:
   - `deepseek-v4-flash` → löses till `deepseek-flash` (med varning i svaret)
   - `deepseek-v4-flash-free` (visas under *OpenCode Free*) → löses till
     provider `opencode-zen` med `https://opencode.ai/zen/v1` — inte den
     provider-raden modellen visades under.
3. **Persistering** med exakt de fyra nycklar `hermes` egen `/model … --global`
   skriver (`model.default`, `model.provider`, `model.base_url`,
   `model.api_mode`) via samma funktion (`cli.save_config_value` →
   `atomic_roundtrip_yaml_update`, 0600). Bytet verifieras sedan genom att
   läsa tillbaka `config.yaml`; stämmer det inte rapporteras fel i stället för
   "klart".

Bytet gäller **standardmodellen** — det vill säga nya Hermes-sessioner. En
pågående chatt kör vidare på sin modell (det står också i popupens fotnot).

Saknas Hermes-venven faller allt tillbaka på att läsa `config.yaml` +
`provider_models_cache.json` och skriva via `hermes config set`. Svaret anger
`"source": "hermes-api" | "config-fallback"`, och popupen visar vilken väg som
användes.

## Installation

```bash
omarchy plugin add https://github.com/alexwest1981/HermesModelSwapper.git --enable
```

Manuellt:

```bash
git clone https://github.com/alexwest1981/HermesModelSwapper.git \
  ~/.config/omarchy/plugins/custom.hermes-model
omarchy-shell shell rescanPlugins
omarchy plugin enable custom.hermes-model
```

Krav: `python3` (systemets räcker för läsning) och Hermes installerat på
`$HERMES_HOME/hermes-agent` för API-vägen. Widgeten kör om sig själv med
Hermes-venvens python när API:t behövs, så inget behöver konfigureras.

## Filer

| Fil | Roll |
|---|---|
| `manifest.json` | Plugin-manifest (`bar-widget`) |
| `BarWidget.qml` | Barens widget + dropdown (`PopupCard`) |
| `hermes_models.py` | Katalog från Hermes, switch via Hermes, fallback-vägar |

## Verifierat (0.2.0)

- `omarchy plugin validate .` → exit 0; inga QML-varningar i `journalctl --user`
- Katalog: `source: hermes-api`, 12 poster (Alias 2, DeepSeek 3, OpenCode Free 7)
- Torrkörning av `switch_model` utan att skriva: gemini-aliasen **vägras** av
  Hermes (Google-nycklar saknas), `deepseek-v4-flash` rättas till
  `deepseek-flash`, `deepseek-v4-flash-free` löses till `opencode-zen`
- Riktigt byte (idempotent mål) mot live-config: `ok: true`, samma
  `model.default`/`provider`/`base_url` efteråt; enda diffen var att
  `api_mode: chat_completions` och `context_length:` tillkom — exakt vad
  `/model … --global` själv skriver
- Persisteringsvägen testad mot sandbox-`HERMES_HOME`: fyra nycklar skrivna,
  rättigheter `0600`

## Licens

MIT
