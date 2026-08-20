#!/usr/bin/env fish
# Совместимость со старым именем. Вся логика теперь в agent.fish.
set -l d (dirname (status --current-filename))
exec $d/agent.fish start
