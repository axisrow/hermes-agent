"""Обёртка Hermes для проектов-потребителей: API-ключ или подписка ChatGPT.

Кладётся в ВАШ проект. Скрывает разницу между двумя способами доступа,
чтобы вызывающий код не менялся при переключении.

Способы доступа
---------------
1. Подписка ChatGPT/Codex (`auth="subscription"`) — токены берутся из
   ~/.hermes/auth.json, оплата не потокенная. Требует один раз:
       hermesx auth login openai-codex
   Hermes создаёт СВОЮ сессию и не конфликтует с Codex CLI / VS Code.
   Модель должна поддерживаться ChatGPT-аккаунтом: `gpt-5.1-codex`
   отвергается с HTTP 400, рабочая — та, что стоит в ~/.codex/config.toml
   (проверено на gpt-5.6-luna).

2. API-ключ (`auth="api_key"`) — обычная потокенная оплата, OPENAI_API_KEY.

Установка Hermes
----------------
ВАЖНО: Hermes занимает очень общие top-level имена (agent, tools,
providers, utils, cli). Проверено: обычный utils.py рядом с вашим кодом
ломает импорт Hermes. Поэтому по умолчанию ставьте его ИЗОЛИРОВАННО:

    uv tool install git+https://github.com/axisrow/hermes-agent@main

и вызывайте как внешний процесс (`hermesx-agent`). Прямой импорт, как в
этом файле, — только если в проекте нет своих модулей с такими именами.
"""

from __future__ import annotations

import os
from typing import Any, Literal

DEFAULT_SUBSCRIPTION_MODEL = "gpt-5.6-luna"
DEFAULT_API_KEY_MODEL = "gpt-4o-mini"


def make_agent(
    *,
    auth: Literal["subscription", "api_key"] = "subscription",
    model: str | None = None,
    toolsets: list[str] | None = None,
    **overrides: Any,
):
    """Собрать AIAgent с погашенной обвязкой Hermes.

    `enabled_toolsets=[]`, `skip_context_files`, `skip_memory`,
    `quiet_mode` — штатные рубильники: они отключают чтение контекстных
    файлов проекта, подсистему памяти и вывод в stdout, оставляя чистый
    цикл «запрос → tool calls → ответ».
    """
    from run_agent import AIAgent

    if auth == "subscription":
        # Резолвер сам обновит access_token по refresh_token при истечении.
        from hermes_cli.auth import resolve_codex_runtime_credentials

        creds = resolve_codex_runtime_credentials()
        cfg: dict[str, Any] = dict(
            base_url=creds["base_url"],
            api_key=creds["api_key"],
            provider="openai-codex",
            api_mode="codex_responses",
            model=model or DEFAULT_SUBSCRIPTION_MODEL,
        )
    else:
        api_key = os.environ.get("OPENAI_API_KEY")
        if not api_key:
            raise RuntimeError("OPENAI_API_KEY не задан (auth='api_key')")
        cfg = dict(  # type: ignore[assignment]
            base_url="https://api.openai.com/v1",
            api_key=api_key,
            provider="openai",
            model=model or DEFAULT_API_KEY_MODEL,
        )

    cfg.update(
        enabled_toolsets=toolsets or [],
        quiet_mode=True,
        skip_context_files=True,
        skip_memory=True,
    )
    cfg.update(overrides)
    return AIAgent(**cfg)


def ask(prompt: str, **kw: Any) -> str:
    """Один вопрос — одна строка ответа.

    Используется agent.chat(); полный agent.run_conversation() возвращает
    Dict[str, Any] со всей телеметрией хода — он нужен, когда важны
    детали (tool calls, usage и пр.).
    """
    return make_agent(**kw).chat(prompt)


if __name__ == "__main__":
    print("subscription:", ask("Reply with exactly: SUBSCRIPTION OK"))
