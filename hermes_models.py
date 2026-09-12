#!/usr/bin/env python3
"""Hermes-modeller för Omarchy-barens widget.

Två saker, båda via Hermes EGEN kod i stället för handskrivna config-nycklar:

  * Vilka modeller Hermes har tillgång till
      → hermes_cli.inventory.build_model_options_payload() — samma payload som
        Hermes egen modellväljare (desktop/TUI/dashboard) bygger, dvs providers
        med giltiga credentials + deras kataloger, plus aliasen i config.yaml.
  * Bytet
      → hermes_cli.model_switch.switch_model() — "core model-switching pipeline
        shared between CLI and gateway" — och persisteras med exakt samma fyra
        nycklar som `hermes` egen `/model … --global` skriver (model.default,
        model.provider, model.base_url, model.api_mode). Urvalsskydden
        (dyr modell/datapolicy) körs före och kan svara confirm_required.

Kommandon (allt som stdout = en rad JSON):

  hermes_models.py list [--refresh]      aktuell modell + grupper
  hermes_models.py current               bara aktuell modell (billigt)
  hermes_models.py set <model> <prov> [--confirm] [--base-url URL]

Kräver Hermes-venven för API-vägen; saknas den faller allt tillbaka på att
läsa config.yaml + provider_models_cache.json och skriva via `hermes config set`
(samma beteende som 0.1.0), och rapporterar vilken väg som användes i
`"source": "hermes-api" | "config-fallback"`.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
CONFIG = HERMES_HOME / "config.yaml"
CACHE = Path(os.environ.get("HERMES_MODELS_CACHE") or HERMES_HOME / "cache" / "hermes-model-widget.json")

REPO_CANDIDATES = [
    Path(os.environ.get("HERMES_REPO") or "")
    if os.environ.get("HERMES_REPO")
    else None,
    HERMES_HOME / "hermes-agent",
    Path("/usr/lib/hermes-agent"),
    Path("/opt/hermes-agent"),
    Path.cwd(),
]
VENV_CANDIDATES = [
    Path(os.environ.get("HERMES_VENV_PYTHON") or "")
    if os.environ.get("HERMES_VENV_PYTHON")
    else None,
    HERMES_HOME / "hermes-agent" / "venv" / "bin" / "python",
    Path("/usr/lib/hermes-agent/venv/bin/python"),
]


# ── var kör vi Hermes-koden? ───────────────────────────────────────────────


def find_repo() -> Path | None:
    for candidate in REPO_CANDIDATES:
        if candidate and (candidate / "hermes_cli" / "inventory.py").is_file():
            return candidate
    return None


def find_venv_python() -> Path | None:
    for candidate in VENV_CANDIDATES:
        if candidate and candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def ensure_venv_python() -> bool:
    """Kör om oss själva med Hermes-venven när API-vägen behövs.

    QML:en anropar alltid `python3 <helper>`, så re-exec håller widgeten
    oförändrad. Skyddas av en env-flagga så vi aldrig kan loopa.
    """
    if os.environ.get("HERMES_MODELS_NO_REEXEC") == "1":
        return False
    if find_repo() is None:
        return False

    venv = find_venv_python()
    if venv is None:
        return False
    try:
        if Path(sys.executable).resolve() == venv.resolve():
            return False
    except OSError:
        return False

    env = dict(os.environ, HERMES_MODELS_NO_REEXEC="1")
    os.execve(str(venv), [str(venv), os.path.abspath(__file__), *sys.argv[1:]], env)


def load_hermes_api():
    """Importera Hermes-modulerna. Returnerar None om de inte finns."""
    repo = find_repo()
    if repo is None:
        return None
    if str(repo) not in sys.path:
        sys.path.insert(0, str(repo))
    try:
        from hermes_cli.config import load_config
        from hermes_cli.inventory import build_model_options_payload, load_picker_context
        from hermes_cli.model_selection_guards import combined_selection_warning
        from hermes_cli.model_switch import switch_model
    except Exception:
        return None

    # CLI:ts egen persistering för /model (samma som `--global` använder),
    # med hermes_cli.config som andrahandsval.
    persist = None
    try:
        from cli import save_config_value as persist  # type: ignore[no-redef]
    except Exception:
        try:
            from hermes_cli.config import set_config_value, unset_config_value

            def persist(key, value):  # type: ignore[misc]
                if value is None:
                    unset_config_value(key)
                else:
                    set_config_value(key, value)
                return True
        except Exception:
            persist = None

    return {
        "build_model_options_payload": build_model_options_payload,
        "combined_selection_warning": combined_selection_warning,
        "load_config": load_config,
        "load_picker_context": load_picker_context,
        "persist": persist,
        "switch_model": switch_model,
    }


# ── läsning ────────────────────────────────────────────────────────────────


def load_config_file() -> dict:
    try:
        import yaml
    except Exception:
        return {}
    try:
        return yaml.safe_load(CONFIG.read_text(encoding="utf-8")) or {}
    except Exception:
        return {}


def current_model(cfg: dict) -> dict:
    model = cfg.get("model") if isinstance(cfg.get("model"), dict) else {}
    return {
        "base_url": str(model.get("base_url") or ""),
        "model": str(model.get("default") or model.get("model") or ""),
        "provider": str(model.get("provider") or ""),
    }


def env_key_names() -> set[str]:
    """Nyckelnamn som faktiskt har ett värde: os.environ + $HERMES_HOME/.env."""
    names = {k for k, v in os.environ.items() if v}
    try:
        for line in (HERMES_HOME / ".env").read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            if value.strip().strip("'\"") and not value.strip().startswith("#"):
                names.add(key.strip().removeprefix("export ").strip())
    except Exception:
        pass
    return names


def missing_key_note(entry: dict) -> str:
    """Vilka nycklar en alias-post behöver men inte har (tom sträng = redo)."""
    if entry.get("api_key"):
        return ""
    key_env = entry.get("key_env")
    if not key_env:
        return ""
    if isinstance(key_env, str):
        wanted = [part.strip() for part in key_env.replace(",", " ").split() if part.strip()]
    elif isinstance(key_env, (list, tuple)):
        wanted = [str(part).strip() for part in key_env if str(part).strip()]
    else:
        return ""
    have = env_key_names()
    missing = [name for name in wanted if name not in have]
    return f"saknar {', '.join(missing)}" if missing else ""


def known_provider_slugs(groups: list[dict]) -> set[str]:
    return {str(item.get("provider") or "") for group in groups for item in group.get("items") or []}


def provider_looks_available(provider: str, known: set[str] | None) -> bool:
    """Avgör med Hermes katalog om en providers nycklar faktiskt fungerar.

    Katalogen byggs av Hermes eget inventory och innehåller bara providers med
    användbara credentials. Saknas providern där finns inga nycklar — då är
    aliaset inte klickbart i praktiken, och det ska synas före klicket.
    """
    if not provider or known is None:
        return True  # ingen uppgift: säg inget hellre än att gissa
    if provider in known:
        return True
    return any(slug.split(":", 1)[0] == provider for slug in known)


def alias_items(cfg: dict, known: set[str] | None = None) -> list[dict]:
    """Alias sparade i config — de namn `hermes`/`/model` accepterar direkt.

    Ett alias kan peka på en provider som saknar nycklar (eller på en nyckel som
    inte finns i .env). Hermes egen switch vägrar då — det visas i raden i
    stället för att bli ett klick som bara ger fel.
    """
    items: list[dict] = []
    seen: set[str] = set()

    direct = cfg.get("model_aliases")
    if isinstance(direct, dict):
        for name, entry in direct.items():
            if not isinstance(entry, dict):
                continue
            model = str(entry.get("model") or "")
            if not model:
                continue
            name = str(name)
            seen.add(name)
            provider = str(entry.get("provider") or "")
            missing = missing_key_note(entry)
            note = model + (f" · {provider}" if provider else "")
            available = True
            problem = ""
            if missing:
                available, problem = False, f"{missing} i env/.env"
            elif not provider_looks_available(provider, known):
                available, problem = False, f"providern {provider} har inga giltiga nycklar hos Hermes"
            items.append({
                "available": available,
                "base_url": str(entry.get("base_url") or ""),
                "label": name,
                "model": model,
                "note": problem or note,
                "provider": provider,
            })

    simple = cfg.get("model")
    simple = simple.get("aliases") if isinstance(simple, dict) else None
    if isinstance(simple, dict):
        for name, value in simple.items():
            if str(name) in seen or not isinstance(value, str) or not value.strip():
                continue
            raw = value.strip()
            provider, _, model = raw.partition("/") if "/" in raw else ("", "", raw)
            items.append({
                "available": provider_looks_available(provider, known),
                "base_url": "",
                "label": str(name),
                "model": model or raw,
                "note": raw,
                "provider": provider,
            })
    return items


def cached_catalog() -> dict | None:
    try:
        data = json.loads(CACHE.read_text(encoding="utf-8"))
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def hermes_catalog() -> dict:
    """Hermes egen modellkatalog (det Hermes faktiskt har tillgång till)."""
    api = load_hermes_api()
    if api is None:
        return {}

    payload = api["build_model_options_payload"](
        api["load_picker_context"](),
        include_unconfigured=False,
    )

    groups = []
    for row in payload.get("providers") or []:
        models = row.get("models") or []
        slug = str(row.get("slug") or "")
        name = str(row.get("name") or slug)
        if not models or slug == "moa":
            continue
        available = bool(row.get("authenticated", True))
        capabilities = row.get("capabilities") if isinstance(row.get("capabilities"), dict) else {}
        items = []
        for model in models:
            model_id = str(model.get("id") if isinstance(model, dict) else model)
            if not model_id:
                continue
            note = name
            caps = capabilities.get(model_id)
            if isinstance(caps, dict):
                flags = [label for key, label in (("reasoning", "tänker"), ("fast", "snabb")) if caps.get(key)]
                if flags:
                    note += " · " + ", ".join(flags)
            items.append({
                "available": available,
                "base_url": "",
                "label": model_id,
                "model": model_id,
                "note": note,
                "provider": slug,
            })
        if items:
            groups.append({"items": items, "kind": "provider", "title": name})

    result = {
        "at": time.time(),
        "groups": groups,
        "model": str(payload.get("model") or ""),
        "provider": str(payload.get("provider") or ""),
    }
    try:
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        CACHE.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass
    return result


def build_payload(refresh: bool) -> dict:
    cfg = load_config_file()
    current = current_model(cfg)

    catalog = hermes_catalog() if refresh else (cached_catalog() or None)
    source = "hermes-api"
    if not catalog:
        catalog = cached_catalog() or {}
        source = "hermes-api" if catalog else "config-fallback"
    if not catalog and not refresh:
        source = "config-fallback"

    groups: list[dict] = []
    catalog_groups = catalog.get("groups") or []
    aliases = alias_items(cfg, known_provider_slugs(catalog_groups) if catalog_groups else None)
    if aliases:
        groups.append({"items": aliases, "kind": "alias", "title": "Alias"})
    for group in catalog_groups:
        groups.append(group)

    # Fallback: providers ur Hermes modellcache när API-vägen inte är möjlig.
    if source == "config-fallback":
        try:
            cache = json.loads((HERMES_HOME / "provider_models_cache.json").read_text(encoding="utf-8"))
        except Exception:
            cache = {}
        for slug, entry in (cache or {}).items():
            models = entry.get("models") if isinstance(entry, dict) else None
            if not isinstance(models, list) or not models:
                continue
            groups.append({
                "items": [{"base_url": "", "label": str(m), "model": str(m), "note": str(slug), "provider": str(slug)}
                          for m in models],
                "kind": "provider",
                "title": str(slug),
            })

    def is_current(item: dict) -> bool:
        return bool(current["model"]) and item["model"] == current["model"] \
            and (item["provider"] or "") == (current["provider"] or "")

    for group in groups:
        for item in group["items"]:
            item["is_current"] = is_current(item)

    at = catalog.get("at")
    return {
        "catalog_at": at,
        "catalog_age_s": int(time.time() - at) if isinstance(at, (int, float)) else None,
        "config_path": str(CONFIG),
        "current": current,
        "groups": groups,
        "item_count": sum(len(g["items"]) for g in groups),
        "ok": True,
        "source": source,
    }


# ── bytet ──────────────────────────────────────────────────────────────────


def hermes_cli(*args: str) -> tuple[bool, str]:
    try:
        proc = subprocess.run(["hermes", *args], capture_output=True, text=True,
                              timeout=90, env=os.environ.copy())
    except FileNotFoundError:
        return False, "hittar inte `hermes` i PATH"
    except subprocess.TimeoutExpired:
        return False, "`hermes` svarade inte inom 90 s"
    return proc.returncode == 0, ((proc.stdout or "") + (proc.stderr or "")).strip()


def apply_via_hermes_api(model: str, provider: str, base_url: str, confirm: bool) -> dict:
    """Låt Hermes egen switch-pipeline göra jobbet."""
    api = load_hermes_api()
    if api is None:
        return {"error": "Hermes-modulerna kunde inte importeras", "ok": False}

    cfg = api["load_config"]()
    current = current_model(cfg if isinstance(cfg, dict) else {})

    # Skydden först (dyr modell/datapolicy) — samma som desktopens väljare kör.
    if not confirm:
        try:
            warning = api["combined_selection_warning"](model, provider=provider, base_url=base_url)
        except Exception:
            warning = None
        if warning is not None:
            return {
                "confirm_message": getattr(warning, "message", str(warning)),
                "confirm_required": True,
                "error": "",
                "ok": False,
            }

    try:
        result = api["switch_model"](
            model,
            current["provider"],
            current["model"],
            current["base_url"],
            "",
            is_global=True,
            explicit_provider=provider,
        )
    except Exception as exc:  # noqa: BLE001
        return {"error": f"Hermes switch_model kastade: {exc}", "ok": False}

    if not getattr(result, "success", False):
        return {"error": getattr(result, "error_message", "") or "modellen kunde inte slås upp", "ok": False}

    # Exakt de nycklar `hermes` egen `/model … --global` skriver, via samma
    # persistering (cli.save_config_value → atomic_roundtrip_yaml_update).
    persist = api.get("persist")
    if persist is None:
        return {"error": "hittade ingen persisteringsväg i Hermes", "ok": False}

    persist("model.context_length", None)
    persist("model.default", result.new_model)
    persist("model.provider", result.target_provider)
    persist("model.base_url", result.base_url or None)
    persist("model.api_mode", result.api_mode or None)

    applied = current_model(api["load_config"]() or {})
    if applied["model"] != result.new_model or applied["provider"] != result.target_provider:
        return {
            "applied": applied,
            "error": f"config.yaml visar {applied['provider']}/{applied['model']} efter bytet",
            "ok": False,
        }

    return {
        "applied": applied,
        "label": f"{result.target_provider}: {result.new_model}",
        "ok": True,
        "resolved_via_alias": getattr(result, "resolved_via_alias", ""),
        "source": "hermes-api",
        "warning": getattr(result, "warning_message", ""),
    }


def apply_via_config_cli(model: str, provider: str, base_url: str) -> dict:
    """Fallback när Hermes-modulerna inte går att importera (0.1.0-beteendet)."""
    steps = []
    for key in ("model.base_url", "model.api_mode", "model.context_length"):
        ok, out = hermes_cli("config", "unset", key)
        steps.append({"key": key, "ok": ok, "output": out})
    for key, value in (("model.default", model), ("model.provider", provider)):
        ok, out = hermes_cli("config", "set", key, value)
        steps.append({"key": key, "ok": ok, "output": out})
        if not ok:
            return {"error": f"kunde inte sätta {key}: {out}", "ok": False, "steps": steps}
    if base_url:
        ok, out = hermes_cli("config", "set", "model.base_url", base_url)
        steps.append({"key": "model.base_url", "ok": ok, "output": out})
        if not ok:
            return {"error": f"kunde inte sätta model.base_url: {out}", "ok": False, "steps": steps}

    applied = current_model(load_config_file())
    if applied["model"] != model or applied["provider"] != provider:
        return {"applied": applied, "error": "config.yaml stämmer inte efter bytet", "ok": False, "steps": steps}
    return {"applied": applied, "label": f"{provider}: {model}", "ok": True,
            "source": "config-fallback", "steps": steps}


def apply_model(model: str, provider: str, base_url: str, confirm: bool) -> dict:
    model, provider, base_url = model.strip(), provider.strip(), base_url.strip()
    if not model:
        return {"error": "model krävs", "ok": False}

    ensure_venv_python()  # startar om oss i Hermes-venven om den finns

    if load_hermes_api() is not None:
        # Utan explicit provider: låt Hermes lösa upp (t.ex. ett alias).
        if not provider:
            result = apply_via_hermes_api(model, "", base_url, confirm)
            if result.get("ok") or result.get("confirm_required"):
                return result
            # Alias/uppslag misslyckades — försök inte gissa vidare.
            return result
        return apply_via_hermes_api(model, provider, base_url, confirm)

    if not provider:
        return {"error": "provider krävs när Hermes-API:t inte är tillgängligt", "ok": False}
    return apply_via_config_cli(model, provider, base_url)


# ── CLI ────────────────────────────────────────────────────────────────────


def parse_args(argv: list[str]) -> tuple[str, list[str], set[str]]:
    command = argv[0] if argv else "list"
    flags = {a for a in argv[1:] if a.startswith("--")}
    positional = [a for a in argv[1:] if not a.startswith("--")]
    return command, positional, flags


def main(argv: list[str]) -> int:
    command, positional, flags = parse_args(argv)

    if command == "current":
        payload = {"current": current_model(load_config_file()), "ok": True}
    elif command == "list":
        if "--refresh" in flags or not cached_catalog():
            ensure_venv_python()
        payload = build_payload(refresh="--refresh" in flags)
    elif command == "set":
        rest = positional + ["", ""]
        payload = apply_model(rest[0], rest[1], "", "--confirm" in flags)
    else:
        payload = {"error": f"okänt kommando: {command}", "ok": False}

    print(json.dumps(payload, ensure_ascii=False))
    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
