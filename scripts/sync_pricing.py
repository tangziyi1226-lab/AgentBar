#!/usr/bin/env python3
"""Synchronize bundled LLM pricing & context windows from public catalogs.

Primary source:  https://models.dev/api.json (sst/models.dev, zero-auth, ETag-enabled)
Fallback source: https://openrouter.ai/api/v1/models

Outputs `Resources/default-pricing.json` as an array of `ModelPriceRule` objects
consumed offline by `PricingCatalog` before or without runtime network sync.
"""

from __future__ import annotations

import argparse
import gzip
import json
import pathlib
import re
import sys
import urllib.request
from typing import Any

MODELS_DEV_URL = "https://models.dev/api.json"
OPENROUTER_URL = "https://openrouter.ai/api/v1/models"

AUTHORITATIVE_PROVIDERS = [
    "anthropic",
    "openai",
    "google",
    "deepseek",
    "moonshotai",
    "moonshotai-cn",
    "zhipuai",
    "zai",
    "xai",
    "volcengine",
    "alibaba",
    "alibaba-cn",
    "qwen",
    "minimax",
    "minimax-cn",
    "mistral",
    "cohere",
    "perplexity",
    "stepfun",
    "meta",
    "google-vertex",
    "amazon-bedrock",
]

CLOUD_AGGREGATOR_PROVIDERS = {
    "volcengine",
    "alibaba",
    "alibaba-cn",
    "google-vertex",
    "amazon-bedrock",
}

SKIPPED_PROVIDER_KEYWORDS = (
    "coding-plan",
    "copilot",
    "free",
    "puter",
)

_SUFFIXES = (":latest", ":free", ":beta", ":exacto", ":thinking", ":1m", ":200k", "-v1:0", "-v2:0")
_BEDROCK_PREFIXES = (
    "us.anthropic.",
    "eu.anthropic.",
    "global.anthropic.",
    "apac.anthropic.",
    "anthropic.",
)


def canonical_model_key(raw: str) -> str:
    s = raw.strip().lower()
    if not s:
        return ""
    if " @ " in s:
        s = s.split(" @ ", 1)[0].strip()
    if "/" in s:
        s = s.rsplit("/", 1)[-1]
    s = re.sub(r"\[\d+[mk]\]$", "", s)
    changed = True
    while changed:
        changed = False
        for suf in _SUFFIXES:
            if s.endswith(suf):
                s = s[: -len(suf)]
                changed = True
    for marker in (".anthropic.", ":anthropic.", ".openai.", ":openai.", ".google.", ":google."):
        if marker in s:
            s = s.split(marker, 1)[1]
            break
    for pref in _BEDROCK_PREFIXES:
        if s.startswith(pref):
            s = s[len(pref) :]
            break
    if "@" in s:
        head, tail = s.rsplit("@", 1)
        if len(tail) == 8 and tail.isdigit():
            s = head
    if re.match(r"^glm-\d\d(-|$)", s):
        s = f"glm-{s[4]}-{s[5]}{s[6:]}"
    s = re.sub(r"(?<=\d)\.(?=\d)", "-", s)
    return s


def _fetch_json(url: str, timeout: int = 25) -> Any:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "AgentBar-PricingSync/0.2",
            "Accept-Encoding": "gzip, deflate",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        if "gzip" in (resp.headers.get("Content-Encoding") or "").lower():
            raw = gzip.decompress(raw)
        return json.loads(raw.decode("utf-8"))


def _to_float(val: Any) -> float | None:
    if val is None or isinstance(val, bool):
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None


def _to_int(val: Any) -> int | None:
    if val is None or isinstance(val, bool):
        return None
    try:
        return int(val)
    except (TypeError, ValueError):
        return None


def parse_models_dev(root: dict[str, Any]) -> list[dict[str, Any]]:
    ordered = [p for p in AUTHORITATIVE_PROVIDERS if p in root]
    if not ordered:
        ordered = sorted(root.keys())
    seen: set[str] = set()
    rules: list[dict[str, Any]] = []

    for provider_id in ordered:
        lower_prov = provider_id.lower()
        if any(kw in lower_prov for kw in SKIPPED_PROVIDER_KEYWORDS):
            continue
        prov_obj = root.get(provider_id)
        if not isinstance(prov_obj, dict):
            continue
        models_obj = prov_obj.get("models")
        if not isinstance(models_obj, dict):
            continue

        for model_id in sorted(models_obj.keys()):
            m = models_obj[model_id]
            if not isinstance(m, dict):
                continue
            cost = m.get("cost")
            if not isinstance(cost, dict):
                continue
            inp = _to_float(cost.get("input")) or 0.0
            out = _to_float(cost.get("output")) or 0.0
            if inp <= 0 and out <= 0:
                continue
            cache_read = _to_float(cost.get("cache_read"))
            if cache_read is None:
                cache_read = inp
            cache_write = _to_float(cost.get("cache_write"))
            if cache_write is None:
                cache_write = inp
            limit_obj = m.get("limit") if isinstance(m.get("limit"), dict) else {}
            raw_ctx = _to_int(limit_obj.get("context")) or 200_000
            ctx = raw_ctx if raw_ctx > 0 else 200_000

            bare = model_id.rsplit("/", 1)[-1].lower()
            if ":" in bare:
                continue
            if lower_prov in CLOUD_AGGREGATOR_PROVIDERS and bare.startswith(("deepseek-", "claude-", "gpt-")):
                continue
            canon = canonical_model_key(bare)
            if not canon or canon in seen:
                continue
            seen.add(canon)
            rules.append(
                {
                    "modelPrefix": bare,
                    "inputPerMillionUSD": round(inp, 6),
                    "outputPerMillionUSD": round(out, 6),
                    "cacheReadPerMillionUSD": round(cache_read, 6),
                    "cacheWritePerMillionUSD": round(cache_write, 6),
                    "defaultContextWindow": ctx,
                }
            )

    rules.sort(key=lambda r: (-len(canonical_model_key(r["modelPrefix"])), r["modelPrefix"]))
    return rules


def parse_openrouter(root: dict[str, Any]) -> list[dict[str, Any]]:
    items = root.get("data")
    if not isinstance(items, list):
        return []
    seen: set[str] = set()
    rules: list[dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        raw_id = item.get("id")
        pricing = item.get("pricing")
        if not isinstance(raw_id, str) or ":" in raw_id or not isinstance(pricing, dict):
            continue
        inp = (_to_float(pricing.get("prompt")) or 0.0) * 1_000_000.0
        out = (_to_float(pricing.get("completion")) or 0.0) * 1_000_000.0
        if inp <= 0 and out <= 0:
            continue
        cr_raw = _to_float(pricing.get("input_cache_read"))
        cw_raw = _to_float(pricing.get("input_cache_write"))
        cache_read = cr_raw * 1_000_000.0 if cr_raw is not None else inp
        cache_write = cw_raw * 1_000_000.0 if cw_raw is not None else inp
        raw_ctx = _to_int(item.get("context_length")) or 200_000
        ctx = raw_ctx if raw_ctx > 0 else 200_000

        bare = raw_id.rsplit("/", 1)[-1].lower()
        canon = canonical_model_key(bare)
        if not canon or canon in seen:
            continue
        seen.add(canon)
        rules.append(
            {
                "modelPrefix": bare,
                "inputPerMillionUSD": round(inp, 6),
                "outputPerMillionUSD": round(out, 6),
                "cacheReadPerMillionUSD": round(cache_read, 6),
                "cacheWritePerMillionUSD": round(cache_write, 6),
                "defaultContextWindow": ctx,
            }
        )
    rules.sort(key=lambda r: (-len(canonical_model_key(r["modelPrefix"])), r["modelPrefix"]))
    return rules


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Sync bundled LLM pricing catalog.")
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=repo_root / "Resources" / "default-pricing.json",
        help="Output JSON path (default: Resources/default-pricing.json)",
    )
    args = parser.parse_args()

    rules: list[dict[str, Any]] = []
    source = ""
    try:
        data = _fetch_json(MODELS_DEV_URL)
        if isinstance(data, dict):
            rules = parse_models_dev(data)
            source = "models.dev"
    except Exception as exc:
        print(f"[warn] models.dev fetch failed ({exc}), trying OpenRouter fallback...", file=sys.stderr)

    if not rules:
        data = _fetch_json(OPENROUTER_URL)
        if isinstance(data, dict):
            rules = parse_openrouter(data)
            source = "openrouter.ai"

    if len(rules) < 50:
        print(f"[error] Refusing to overwrite catalog with only {len(rules)} rules.", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    serialized = json.dumps(rules, indent=2, ensure_ascii=False) + "\n"
    args.output.write_text(serialized, encoding="utf-8")
    print(f"Synced {len(rules)} model pricing rules from {source} -> {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
