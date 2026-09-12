#!/usr/bin/env python3
"""Hermes-modeller för Omarchy-barens widget.

Läser vad Hermes SJÄLV har sparat — ingen nätverksåtkomst, ingen Hermes-venv:
  * ~/.hermes/config.yaml          → model.default/provider/base_url, model_aliases,
                                     model.aliases, custom_providers[*].models
  * ~/.hermes/provider_models_cache.json → de kataloger Hermes har hämtat och sparat

Kommandon:
  hermes_models.py list                      → JSON med nuvarande modell + grupper
  hermes_models.py set <model> <prov> <url>  → byter standardmodell via `hermes config set`
  hermes_models.py current                   → JSON med bara nuvarande modell

Allt skrivs som en rad JSON på stdout. Fel fångas och rapporteras som {"ok": false}.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

HOME = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
CONFIG = HOME / "config.yaml"
PROVIDER_CACHE = HOME / "provider_models_cache.json"


# ── läsning ────────────────────────────────────────────────────────────────


def load_config() -> dict:
    """config.yaml via PyYAML (systemets python3 har den; annars tom config)."""
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


def alias_items(cfg: dict) -> list[dict]:
    """Alias sparade i config — de namn `hermes`/`/model` accepterar direkt."""
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
            items.append({
                "base_url": str(entry.get("base_url") or ""),
                "label": name,
                "model": model,
                "note": f"{model}"
                        + (f" · {entry['provider']}" if entry.get("provider") else "")
                        + ("" if entry.get("base_url") else ""),
                "provider": str(entry.get("provider") or ""),
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
                "base_url": "",
                "label": str(name),
                "model": model or raw,
                "note": raw,
                "provider": provider,
            })

    return items


def provider_items(cfg: dict, cache: dict) -> list[dict]:
    """Sparade modeller per provider — config-först, sen Hermes egen modellcache."""
    per_provider: dict[str, dict] = {}

    def add(provider: str, model: str, base_url: str, source: str) -> None:
        provider = (provider or "").strip()
        model = (model or "").strip()
        if not provider or not model:
            return
        bucket = per_provider.setdefault(provider, {"base_url": base_url, "models": [], "source": source})
        if model not in bucket["models"]:
            bucket["models"].append(model)
        if base_url and not bucket["base_url"]:
            bucket["base_url"] = base_url

    # 1. Modeller som config.yaml sparar per provider (custom_providers / providers).
    for section in ("custom_providers", "providers"):
        raw = cfg.get(section)
        entries = raw.items() if isinstance(raw, dict) else []
        for key, entry in entries:
            if not isinstance(entry, dict):
                continue
            provider = str(entry.get("name") or entry.get("slug") or key)
            base_url = str(entry.get("base_url") or "")
            models = entry.get("models")
            if isinstance(models, dict):
                for model in models:
                    add(provider, str(model), base_url, "config")
            elif isinstance(models, list):
                for model in models:
                    add(provider, str(model), base_url, "config")

    # 2. Hermes modellcache: kataloger den faktiskt har hämtat per provider.
    for slug, entry in (cache or {}).items():
        if not isinstance(entry, dict):
            continue
        models = entry.get("models")
        if isinstance(models, list):
            for model in models:
                add(str(slug), str(model), "", "cache")

    items = []
    for provider, bucket in sorted(per_provider.items()):
        for model in bucket["models"]:
            items.append({
                "base_url": bucket["base_url"],
                "label": model,
                "model": model,
                "note": provider + (" · config" if bucket["source"] == "config" else "")
                        + ("" if bucket["source"] == "config" else " · Hermes-cache"),
                "provider": provider,
            })
    return items


def load_cache() -> dict:
    try:
        return json.loads(PROVIDER_CACHE.read_text(encoding="utf-8"))
    except Exception:
        return {}


def build_payload() -> dict:
    cfg = load_config()
    cache = load_cache()
    current = current_model(cfg)

    def is_current(item: dict) -> bool:
        return bool(current["model"]) \
            and item["model"] == current["model"] \
            and (item["provider"] or "") == (current["provider"] or "")

    groups = []
    aliases = alias_items(cfg)
    if aliases:
        groups.append({"items": aliases, "kind": "alias", "title": "Alias"})

    per_provider = provider_items(cfg, cache)
    for provider in sorted({item["provider"] for item in per_provider}):
        rows = [item for item in per_provider if item["provider"] == provider]
        groups.append({"items": rows, "kind": "provider", "title": provider})

    for group in groups:
        for item in group["items"]:
            item["is_current"] = is_current(item)

    return {
        "config_path": str(CONFIG),
        "current": current,
        "generated_at": int(__import__("time").time()),
        "groups": groups,
        "item_count": sum(len(group["items"]) for group in groups),
        "ok": True,
    }


# ── skrivning (bytet) ──────────────────────────────────────────────────────


def hermes(*args: str) -> tuple[bool, str]:
    """Kör `hermes <args...>` och returnera (ok, utdata)."""
    try:
        proc = subprocess.run(
            ["hermes", *args],
            capture_output=True,
            text=True,
            timeout=60,
            env=os.environ.copy(),
        )
    except FileNotFoundError:
        return False, "hittar inte `hermes` i PATH"
    except subprocess.TimeoutExpired:
        return False, "`hermes` svarade inte inom 60 s"

    out = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode == 0, out.strip()


def apply_model(model: str, provider: str, base_url: str) -> dict:
    """Sätt standardmodell.

    Speglar vad Hermes egen `/model … --global` skriver: model.default,
    model.provider och (när målet har en egen endpoint) model.base_url. Ärvda
    nycklar för den FÖRRA modellen rensas först — annars pekar en kvarvarande
    base_url/api_mode på fel leverantör.
    """
    model = (model or "").strip()
    provider = (provider or "").strip()
    base_url = (base_url or "").strip()

    if not model or not provider:
        return {"error": "model och provider krävs", "ok": False}

    steps: list[dict] = []
    for key in ("model.base_url", "model.api_mode", "model.context_length"):
        ok, out = hermes("config", "unset", key)
        steps.append({"key": key, "ok": ok, "output": out})

    for key, value in (("model.default", model), ("model.provider", provider)):
        ok, out = hermes("config", "set", key, value)
        steps.append({"key": key, "ok": ok, "output": out})
        if not ok:
            return {"error": f"kunde inte sätta {key}: {out}", "ok": False, "steps": steps}

    if base_url:
        ok, out = hermes("config", "set", "model.base_url", base_url)
        steps.append({"key": "model.base_url", "ok": ok, "output": out})
        if not ok:
            return {"error": f"kunde inte sätta model.base_url: {out}", "ok": False, "steps": steps}

    # Verifiera mot filen i stället för att lita på kommandots exitkod.
    applied = current_model(load_config())
    if applied["model"] != model or applied["provider"] != provider:
        return {
            "error": f"config.yaml visar {applied['provider']}/{applied['model']} efter bytet",
            "ok": False,
            "steps": steps,
        }

    return {
        "applied": applied,
        "label": f"{provider}: {model}",
        "ok": True,
        "steps": steps,
    }


# ── CLI ────────────────────────────────────────────────────────────────────


def main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else "list"

    if command == "current":
        payload = {"current": current_model(load_config()), "ok": True}
    elif command == "list":
        payload = build_payload()
    elif command == "set":
        rest = argv[2:] + ["", "", ""]
        payload = apply_model(rest[0], rest[1], rest[2])
    else:
        payload = {"error": f"okänt kommando: {command}", "ok": False}

    print(json.dumps(payload, ensure_ascii=False))
    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
