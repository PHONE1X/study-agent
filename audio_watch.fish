#!/usr/bin/env fish
# Сторож ответвления.
#
# Зачем он нужен. В режиме link копия сигнала уходит в agent-capture по связям,
# которые мы создали вручную через pw-link. Но маршрутизацией потоков заведует
# WirePlumber, и когда меняется устройство вывода приложения, он пересоздаёт
# связи этого потока -- вместе с нашими. Захват при этом обрывается молча: звук
# у тебя есть, транскрипт перестаёт расти, и заметить это можно только постфактум.
#
# Сторож раз в несколько секунд проверяет, живы ли связи, и восстанавливает их.
# Проверка стоит одного вызова pw-dump, поэтому нагрузка незаметная.
#
# Ничего не делает, если: режим не link, включён тихий режим (там поток и так
# внутри agent-capture), или захваченный поток вообще исчез -- последнее видно
# в `agent status` отдельным предупреждением, и чинится выбором источника.

set -g SA_DIR (dirname (status --current-filename))
source $SA_DIR/audio_lib.fish

if not set -q AUDIO_WATCH_INTERVAL
    set -g AUDIO_WATCH_INTERVAL 5
end

function watch_once
    set -l mode (agent_audio_state_get mode | string collect)
    if test "$mode" != link
        return 0
    end
    if agent_silenced
        return 0
    end
    set -l node_id (agent_audio_state_get node_id | string collect)
    if test -z "$node_id"
        return 0
    end

    set -l health (agent_pw_capture_health | string collect)
    set -l alive (echo $health | cut -d' ' -f1)
    set -l links (echo $health | cut -d' ' -f2)

    if test "$alive" != "1"
        # Поток исчез. Так бывает не только когда приложение закрыли, но и
        # когда просто включили СЛЕДУЮЩЕЕ видео: браузер закрывает старый
        # поток и открывает новый, с новым node.id и новым object.serial.
        # Раньше сторож в этом месте просто выходил, и дальше молча ломалось
        # всё, что опирается на записанный поток: захват не возобновлялся, а
        # `agent mute` падал с «Не получилось включить тихий режим», потому
        # что pactl move-sink-input получал номер несуществующего потока.
        #
        # Перецепляемся сами, но только когда это однозначно: у того же
        # приложения ровно один играющий поток. Если их несколько -- выбирать
        # за пользователя нельзя, можно попасть не на то видео.
        set -l app (agent_audio_state_get app | string collect)
        if test -z "$app"
            return 0
        end
        set -l cand (agent_pw_streams | jq -c --arg a "$app" 'select(.app == $a)')
        if test (count $cand) -ne 1
            if test (count $cand) -gt 1
                echo "AUDIO WATCH: у «$app» сейчас несколько потоков — не угадываю, выбери источник: agent start" >&2
            end
            return 0
        end
        set -l new_id (echo $cand[1] | jq -r '.id')
        set -l new_serial (echo $cand[1] | jq -r '.serial // empty')
        set -l new_media (echo $cand[1] | jq -r '.media')
        set -l pm (agent_pw_link_capture $new_id | string collect)
        if test -z "$pm"
            echo "AUDIO WATCH: нашёл новый поток «$app», но ответвить не удалось" >&2
            return 0
        end
        # serial обязателен: на нём держатся mute/unmute. Без его обновления
        # захват бы ожил, а тихий режим остался бы сломанным.
        agent_state_set node_id "$new_id" serial "$new_serial" media "$new_media" port_mode "$pm"
        echo "AUDIO WATCH: поток сменился, перецепился на «$app — $new_media» (порты: $pm)"
        return 0
    end
    if test "$links" != "0"
        return 0
    end

    set -l pm (agent_pw_link_capture $node_id | string collect)
    if test -n "$pm"
        agent_state_set port_mode "$pm"
        echo "AUDIO WATCH: ответвление отвалилось и восстановлено (порты: $pm)"
    else
        echo "AUDIO WATCH: ответвление отвалилось, восстановить не удалось" >&2
    end
end

if test "$argv[1]" = "--once"
    watch_once
    exit 0
end

while true
    sleep $AUDIO_WATCH_INTERVAL
    watch_once
end
