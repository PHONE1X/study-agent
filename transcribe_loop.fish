#!/usr/bin/env fish
# Тонкая обёртка: сама логика теперь в transcribe_stream.py.
#
# Почему не fish. Новый цикл держит непрерывный поток parec и нарезает из него
# перекрывающиеся окна, то есть работает с сырыми байтами и склеивает тексты по
# словам. На fish это выходило громоздко и хрупко. Юнит systemd и команды
# `agent` остались прежними -- меняется только то, что внутри.
#
# Прошлая версия сохранена рядом: transcribe_loop.fish.bak-*
exec python3 (dirname (status --current-filename))/transcribe_stream.py
