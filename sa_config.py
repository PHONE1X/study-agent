#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Чтение ~/.config/study-agent/config.env для python-частей агента.

Формат KEY=значение выбран ровно потому, что этот же файл читают
fish-скрипты (sa_config.fish). Держать две разные формы одних и тех же
настроек -- верный способ однажды поправить одну и забыть про вторую.
"""

import os

CONFIG_PATH = os.path.expanduser("~/.config/study-agent/config.env")

DEFAULTS = {
    "SA_VAULT_DIR": "~/Documents/Obsidian",
    "SA_STUDY_SUBDIR": "Обучение",
    "SA_USER_NAME": "участнику",
    "SA_LANG": "ru",
    "SA_WHISPER_URL": "http://127.0.0.1:8080/inference",
    "SA_OLLAMA_URL": "http://127.0.0.1:11434/api/generate",
    "SA_CAPTURE_DEVICE": "agent-capture.monitor",
}

_values = dict(DEFAULTS)

try:
    with open(CONFIG_PATH, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            key, val = key.strip(), val.strip().strip('"').strip("'")
            if key in _values:
                _values[key] = val
except OSError:
    pass


def get(key):
    """Значение настройки; ~ в путях разворачивается."""
    return os.path.expanduser(_values.get(key, ""))


def study_dir():
    return os.path.join(get("SA_VAULT_DIR"), _values["SA_STUDY_SUBDIR"])
