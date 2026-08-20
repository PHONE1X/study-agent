#!/usr/bin/env fish
# Создаёт виртуальное устройство agent-capture (null sink). Идемпотентно --
# безопасно вызывать повторно, в том числе из Hyprland exec-once.
#
# ВАЖНОЕ ОТЛИЧИЕ ОТ СТАРОЙ ВЕРСИИ: петля прослушивания здесь больше НЕ
# создаётся и устройство вывода здесь больше НЕ зашито. Петля появляется
# только в момент выбора источника (route_to_capture.fish) и наводится на то
# устройство, где звук играл до захвата. Благодаря этому запуск агента
# перестал перетаскивать звук на конкретный ЦАП.

set -g SA_DIR (dirname (status --current-filename))
source $SA_DIR/audio_lib.fish

set -l sink_exists (agent_sink_id | string collect)
if test -z "$sink_exists"
    pactl load-module module-null-sink \
        sink_name=$AGENT_SINK \
        sink_properties=device.description=$AGENT_SINK >/dev/null
    echo "Виртуальное устройство $AGENT_SINK создано."
else
    echo "Виртуальное устройство $AGENT_SINK уже есть (id $sink_exists)."
end
