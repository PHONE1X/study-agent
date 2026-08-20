#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Поиск ответа в заметках ПРОШЛЫХ сессий.

ЗАЧЕМ

Вопрос могут задать на седьмой день курса, а ответ прозвучал на втором.
В текущем транскрипте его нет, и без этого поиска модель либо разводит
руками, либо -- что хуже -- выдумывает. Проверено вживую: на вопрос
«как часто ротировать ключи по регламенту» модель бодро ответила «раз в
90 дней», хотя ни в транскрипте, ни в заметках такого не было нигде.

КАК

Из вопроса берутся значимые слова, по ним ищутся строки во всех заметках
вольта, кроме текущей сессии. Ранжирование простое: сколько разных слов
вопроса встретилось в строке. Возвращаются лучшие строки с указанием, из
какой сессии они взяты, -- источник модель обязана назвать в ответе.

Полноценного поиска по смыслу тут нет и не нужно: заметки короткие, а
совпадение по словам на терминах (имена, названия, числа) работает лучше
любых эмбеддингов, которые пришлось бы держать в памяти.

ИСПОЛЬЗОВАНИЕ
    find_in_notes.py "текст вопроса" [исключить-папку-сессии]
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sa_config

VAULT = sa_config.study_dir()
MAX_LINES = 12       # больше в промпт тащить незачем -- размывает вопрос
MIN_WORD = 4
STEM = 5
MIN_HITS = 2         # строка с одним общим словом -- это шум

STOP = {
    "который", "которые", "которая", "чтобы", "потому", "поэтому", "если",
    "когда", "нужно", "нужен", "можно", "этот", "эта", "это", "там", "здесь",
    "будет", "было", "были", "быть", "весь", "всех", "всего", "тоже", "также",
    "очень", "просто", "только", "какой", "какая", "какие", "сколько", "часто",
    "наш", "наши", "нашему", "нашем", "вопрос", "ответ",
}

_word = re.compile(r"[а-яёa-z0-9]+", re.IGNORECASE)


def stems(text):
    out = set()
    for w in _word.findall(text.lower()):
        if len(w) < MIN_WORD or w in STOP:
            continue
        out.add(w[:STEM])
    return out


def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        return
    q = stems(sys.argv[1])
    if not q:
        return
    skip = sys.argv[2] if len(sys.argv) > 2 else ""

    if not os.path.isdir(VAULT):
        return

    found = []
    for session in sorted(os.listdir(VAULT)):
        path = os.path.join(VAULT, session)
        if not os.path.isdir(path) or session == skip or session.startswith("_"):
            continue
        for name in sorted(os.listdir(path)):
            # Транскрипт не берём: он сырой, длинный и повторяет то, что уже
            # разобрано в заметках. Ищем по конспектам и сегментам.
            if not name.endswith(".md") or name.startswith("Транскрипт"):
                continue
            if ".bak" in name:
                continue
            try:
                with open(os.path.join(path, name), encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if len(line) < 25 or line.startswith("#"):
                            continue
                        hits = len(q & stems(line))
                        if hits >= MIN_HITS:
                            found.append((hits, session, line.lstrip("- ").strip()))
            except OSError:
                continue

    if not found:
        return
    found.sort(key=lambda x: -x[0])
    seen = set()
    for _, session, line in found[:MAX_LINES * 2]:
        if line in seen:
            continue
        seen.add(line)
        print("[%s] %s" % (session, line))
        if len(seen) >= MAX_LINES:
            break


if __name__ == "__main__":
    main()
