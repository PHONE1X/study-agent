#!/usr/bin/env fish
# Выбор источника звука для захвата.
#
# По умолчанию работает в режиме "link": поток приложения НЕ трогается вообще,
# от него лишь ответвляется копия сигнала в agent-capture. Приложение как
# играло на своё устройство, так и играет -- в pavucontrol у него по-прежнему
# стоит твой ЦАП, а не agent-capture.
#
# Флаг --move включает старый режим с физическим переносом потока. Нужен
# только как запасной путь, если ответвление почему-то не работает.

set -g SA_DIR (dirname (status --current-filename))
source $SA_DIR/audio_lib.fish

set -l want_move false
if contains -- --move $argv
    set want_move true
end

$SA_DIR/setup_audio_routing.fish >/dev/null

# Снимаем предыдущий захват, чтобы не копились висячие связи.
agent_capture_release >/dev/null 2>&1

if not agent_pw_available
    set want_move true
    echo "pw-link / pw-dump не найдены — использую запасной режим переноса потока."
end

# ==========================================================================
# Режим link
# ==========================================================================

if test "$want_move" = "false"
    # Петля AGENT-MONITOR нужна только запасному режиму. В режиме ответвления
    # она вредна: приложение и так играет на своё устройство, а петля добавляет
    # вторую копию того же звука с задержкой -- на слух это эхо.
    agent_loopback_destroy >/dev/null 2>&1

    set -l lines (agent_pw_streams)
    # Сам agent-capture не является Stream/Output/Audio, поэтому в список не
    # попадает. Отфильтровываем лишь служебные петли, если они остались.
    set -l lines (printf '%s\n' $lines | jq -c --arg tag "$AGENT_MONITOR_TAG" 'select(.media != $tag and .app != "Loopback")')

    if test (count $lines) -eq 0
        echo "Играющих аудиопотоков не найдено."
        echo "Сначала включи воспроизведение в нужном приложении, потом запусти снова."
        exit 1
    end

    echo "Какой звук захватывать?"
    echo ""
    for i in (seq (count $lines))
        set -l app (echo $lines[$i] | jq -r '.app')
        set -l media (echo $lines[$i] | jq -r '.media')
        echo "  $i) $app — $media"
    end
    echo ""

    read -P "Номер: " choice
    if not string match -qr '^\d+$' -- $choice
        echo "Некорректный ввод."
        exit 1
    end
    if test "$choice" -lt 1 -o "$choice" -gt (count $lines)
        echo "Некорректный ввод."
        exit 1
    end

    set -l chosen $lines[$choice]
    set -l node_id (echo $chosen | jq -r '.id')
    set -l app_name (echo $chosen | jq -r '.app')
    set -l media_name (echo $chosen | jq -r '.media')
    set -l serial (echo $chosen | jq -r '.serial // empty')

    set -l port_mode (agent_pw_link_capture $node_id | string collect)
    if test -z "$port_mode"
        echo ""
        echo "Ответвить копию сигнала не удалось. Пробую запасной режим переноса."
        exec $SA_DIR/route_to_capture.fish --move
    end

    agent_state_set mode link node_id "$node_id" app "$app_name" media "$media_name" \
        serial "$serial" port_mode "$port_mode"

    echo ""
    echo "Захват: $app_name — $media_name"
    echo "Устройство вывода приложения не тронуто: звук идёт туда же, куда и шёл."
    echo ""
    if test "$port_mode" = monitor
        echo "Режим портов: monitor — приглушать приложение можно как угодно,"
        echo "на запись это не повлияет."
    else
        echo "Режим портов: output. Приглушать приложение вручную нельзя: это"
        echo "обрежет и запись тоже."
    end
    echo ""
    echo "Чтобы перестать слышать звук, но продолжать писать:  agent mute"
    echo "Вернуть звук обратно:                                agent unmute"
    exit 0
end

# ==========================================================================
# Режим move (запасной)
# ==========================================================================

set -l loop_si (agent_loopback_sink_input_id | string collect)

set -l lines (pactl -f json list sink-inputs | jq -c --arg loop "$loop_si" '
    .[] | select(($loop == "") or ((.index|tostring) != $loop))')

if test (count $lines) -eq 0
    echo "Играющих аудиопотоков не найдено."
    exit 1
end

echo "Какой звук захватывать? (режим переноса потока)"
echo ""
for i in (seq (count $lines))
    set -l item $lines[$i]
    set -l app (echo $item | jq -r '.properties["application.name"] // "?"')
    set -l media (echo $item | jq -r '.properties["media.name"] // "?"')
    set -l snk (echo $item | jq -r '.sink')
    set -l snk_name (agent_sink_name_by_index "$snk" | string collect)
    set -l where ""
    if test "$snk_name" = "$AGENT_SINK"
        set where "  <- уже захвачен"
    else
        set -l desc (agent_sink_description "$snk_name" | string collect)
        set where "  (играет: $desc)"
    end
    echo "  $i) $app — $media$where"
end
echo ""

read -P "Номер: " choice
if not string match -qr '^\d+$' -- $choice
    echo "Некорректный ввод."
    exit 1
end
if test "$choice" -lt 1 -o "$choice" -gt (count $lines)
    echo "Некорректный ввод."
    exit 1
end

set -l chosen $lines[$choice]
set -l target_id (echo $chosen | jq -r '.index')
set -l app_name (echo $chosen | jq -r '.properties["application.name"] // "?"')
set -l media_name (echo $chosen | jq -r '.properties["media.name"] // "?"')
set -l cur_sink_idx (echo $chosen | jq -r '.sink')
set -l orig_sink (agent_sink_name_by_index "$cur_sink_idx" | string collect)

if test "$orig_sink" = "$AGENT_SINK"
    set orig_sink (agent_audio_state_get original_sink | string collect)
end
if test -z "$orig_sink"
    set orig_sink (agent_default_sink | string collect)
end

# Сначала поднимаем петлю на нужное устройство, только потом уводим
# приложение. Иначе на долю секунды звук уходит в никуда.
agent_loopback_ensure "$orig_sink"
pactl move-sink-input $target_id $AGENT_SINK
agent_state_set mode move captured_sink_input "$target_id" app "$app_name" \
    media "$media_name" original_sink "$orig_sink"

set -l orig_desc (agent_sink_description "$orig_sink" | string collect)
echo ""
echo "Захват: $app_name — $media_name (поток $target_id) -> $AGENT_SINK"
echo "Слышно через петлю AGENT-MONITOR на: $orig_desc"
echo ""
echo "  agent out   — сменить устройство прослушивания"
echo "  agent mute  — перестать слышать (захват продолжится)"
