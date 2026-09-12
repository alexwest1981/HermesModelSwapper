# HermesModelSwapper

En Omarchy-bar-widget som visar Hermes nuvarande standardmodell och byter den
med ett klick.

![widget i baren](bar.png)

## Vad den gör

- Visar robotikonen + aktuell modell i baren (högersektionen).
- Klick öppnar en dropdown med allt Hermes har sparat:
  - **Alias** — `model_aliases` / `model.aliases` från `~/.hermes/config.yaml`
  - **Per provider** — providers sparade i config samt katalogerna i
    `~/.hermes/provider_models_cache.json` (de modeller Hermes själv har hämtat)
- Aktuell modell markeras **AKTIV**.
- Ett val skriver `model.default` + `model.provider` (och `model.base_url` när
  målet har en egen endpoint). Ärvda nycklar för den förra modellen
  (`base_url`, `api_mode`, `context_length`) rensas först, så inget pekar kvar
  på fel leverantör.
- Högerklick läser om listan.

Bytet gäller **standardmodellen** — det vill säga nya Hermes-sessioner. En
pågående session behåller sin modell.

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

Kräver `hermes` i `PATH` (skrivningen sker via `hermes config set`) samt
`python3` med PyYAML för läsningen. Ingen nätverksåtkomst, ingen Hermes-venv.

## Filer

| Fil | Roll |
|---|---|
| `manifest.json` | Plugin-manifest (`bar-widget`) |
| `BarWidget.qml` | Barens widget + dropdown (`PopupCard`) |
| `hermes_models.py` | Läser Hermes-konfigurationen, byter modell |

## Verifierat

- `omarchy plugin validate .` → exit 0
- `omarchy plugin list` → `enabled`, `third-party`, `bar-widget`
- Inga QML-varningar i `journalctl --user` från widgeten
- Skrivvägen testad mot en sandbox-`HERMES_HOME` (aldrig mot live-config)
