#!/usr/bin/env fish
# Общая библиотека аудиослоя учебного агента. Сама по себе ничего не делает --
# только определяет функции. Подключается через `source` из остальных скриптов.
#
# ================= ДВА РЕЖИМА ЗАХВАТА =================
#
# РЕЖИМ "link" (основной, неинвазивный).
#
#   Поток приложения НЕ трогается вообще. Он как играл на своё устройство, так и
#   играет. Мы лишь дополнительно ответвляем от него копию сигнала в
#   agent-capture через pw-link. В PipeWire один выходной порт можно подключить
#   к нескольким приёмникам одновременно, поэтому копия не отнимает оригинал.
#
#     [Firefox] ──┬──▶ [KM-HIFI]        (как обычно, ничего не изменилось)
#                 └──▶ [agent-capture] ──▶ .monitor ──▶ [whisper]
#
#   Ответвляем по возможности от МОНИТОРНЫХ портов (monitor_FL/FR). Их смысл в
#   том, что они несут сигнал ДО применения громкости и mute потока. Значит,
#   можно приглушить приложение в pavucontrol -- себе тишина, агенту полный
#   сигнал. Если мониторных портов у потока нет, откатываемся на обычные
#   выходные порты: приложение всё равно остаётся на своём устройстве, но mute
#   в этом случае обрежет и запись. Режим всегда виден в `agent status`.
#
# РЕЖИМ "move" (запасной, старый).
#
#   Поток физически переносится в agent-capture, а слышимость возвращается
#   отдельной петлёй AGENT-MONITOR. Нужен, если pw-link недоступен или граф
#   почему-то не даёт ответвиться.

set -g AGENT_SINK agent-capture
set -g AGENT_MONITOR agent-capture.monitor
set -g AGENT_MONITOR_TAG AGENT-MONITOR
set -g AUDIO_STATE ~/.local/share/study-agent/audio_state.json
set -g LOOPBACK_LATENCY 50

# ==========================================================================
# Общие справки по sink'ам
# ==========================================================================

function agent_sink_id
    pactl list sinks short | awk -F'\t' -v s="$AGENT_SINK" '$2==s{print $1}' | head -n1
end

function agent_sink_name_by_index --argument-names idx
    test -n "$idx"; or return 1
    pactl list sinks short | awk -F'\t' -v i="$idx" '$1==i{print $2}' | head -n1
end

function agent_sink_description --argument-names name
    # Всегда печатает ровно одну непустую строку. В fish конкатенация строки с
    # ПУСТОЙ подстановкой команды даёт ноль аргументов, то есть молча съедает
    # всю строку целиком -- поэтому пустой вывод здесь недопустим.
    if test -z "$name"
        echo "(не определено)"
        return 0
    end
    set -l d (pactl -f json list sinks 2>/dev/null | jq -r --arg n "$name" '.[] | select(.name==$n) | .description // .name' | head -n1 | string collect)
    if test -z "$d"
        echo $name
    else
        echo $d
    end
end

function agent_real_sinks
    pactl list sinks short | awk -F'\t' -v s="$AGENT_SINK" '$2!=s{print $2}'
end

function agent_default_sink
    set -l d (pactl get-default-sink 2>/dev/null | string collect)
    if test -z "$d" -o "$d" = "$AGENT_SINK"
        set d (agent_real_sinks | head -n1 | string collect)
    end
    echo $d
end

# ==========================================================================
# Состояние захвата
# ==========================================================================

function agent_state_set --description "agent_state_set ключ значение [ключ значение ...]"
    mkdir -p (dirname $AUDIO_STATE)
    if not test -f $AUDIO_STATE
        echo '{}' > $AUDIO_STATE
    end
    set -l tmp $AUDIO_STATE.tmp
    set -l filter '.'
    set -l jqargs
    set -l n 0
    while test (count $argv) -ge 2
        set n (math $n + 1)
        set -a jqargs --arg "k$n" "$argv[1]" --arg "v$n" "$argv[2]"
        set filter "$filter | .[\$k$n] = \$v$n"
        set argv $argv[3..-1]
    end
    jq $jqargs "$filter" $AUDIO_STATE > $tmp; and mv $tmp $AUDIO_STATE
end

function agent_state_set_json --argument-names key rawjson
    mkdir -p (dirname $AUDIO_STATE)
    if not test -f $AUDIO_STATE
        echo '{}' > $AUDIO_STATE
    end
    set -l tmp $AUDIO_STATE.tmp
    jq --arg k "$key" --argjson v "$rawjson" '.[$k] = $v' $AUDIO_STATE > $tmp; and mv $tmp $AUDIO_STATE
end

function agent_audio_state_get --argument-names key
    if test -f $AUDIO_STATE
        jq -r --arg k "$key" '.[$k] // empty' $AUDIO_STATE
    end
end

function agent_state_clear
    mkdir -p (dirname $AUDIO_STATE)
    echo '{}' > $AUDIO_STATE
end

# ==========================================================================
# РЕЖИМ link: ответвление через pw-link
# ==========================================================================

function agent_pw_available
    command -q pw-dump; and command -q pw-link
end

function agent_pw_streams --description "JSON-строки по одному играющему потоку приложения"
    # Служебные петли PipeWire (output.loopback-*, input.loopback-*) исключаем:
    # это наши же вспомогательные объекты, и захват такой петли дал бы
    # акустическую обратную связь.
    pw-dump 2>/dev/null | jq -c '
        .[]
        | select(.type == "PipeWire:Interface:Node")
        | select(.info.props["media.class"] == "Stream/Output/Audio")
        | select(((.info.props["node.name"] // "") | test("^(output|input)[.]loopback"; "i")) | not)
        | {
            id: .id,
            serial: (.info.props["object.serial"] // null),
            app: (.info.props["application.name"] // .info.props["node.name"] // "?"),
            media: (.info.props["media.name"] // "?"),
            node: (.info.props["node.name"] // "")
          }'
end

function agent_pw_ports --argument-names node_id --description "id<TAB>направление<TAB>имя<TAB>канал"
    test -n "$node_id"; or return 1
    pw-dump 2>/dev/null | jq -r --argjson nid "$node_id" '
        .[]
        | select(.type == "PipeWire:Interface:Port")
        | select((.info.props["node.id"] // -1) == $nid)
        | [ (.id|tostring),
            (.info.direction // .info.props["port.direction"] // ""),
            (.info.props["port.name"] // ""),
            (.info.props["audio.channel"] // "")
          ] | @tsv'
end

function agent_pw_node_id_by_name --argument-names nname
    pw-dump 2>/dev/null | jq -r --arg n "$nname" '
        .[] | select(.type == "PipeWire:Interface:Node")
            | select(.info.props["node.name"] == $n) | .id' | head -n1
end

function agent_pw_link_capture --argument-names node_id --description "Ответвляет копию потока в agent-capture. Печатает режим портов: monitor или output"
    test -n "$node_id"; or return 1

    set -l sink_node (agent_pw_node_id_by_name $AGENT_SINK | string collect)
    if test -z "$sink_node"
        echo "agent_pw_link_capture: не найден узел $AGENT_SINK" >&2
        return 1
    end

    # Входные порты приёмника.
    set -l in_ports (agent_pw_ports $sink_node | awk -F'\t' '$2=="input" || $2=="in" {print $1"\t"$4}')
    if test (count $in_ports) -eq 0
        echo "agent_pw_link_capture: у $AGENT_SINK нет входных портов" >&2
        return 1
    end

    # Выходные порты источника. Мониторные предпочтительнее: они несут сигнал
    # до применения громкости и mute, поэтому приглушение приложения не глушит
    # запись.
    set -l all_out (agent_pw_ports $node_id | awk -F'\t' '$2=="output" || $2=="out" {print $1"\t"$3"\t"$4}')
    set -l mon_ports (printf '%s\n' $all_out | awk -F'\t' '$2 ~ /^monitor/ {print $1"\t"$3}')
    set -l reg_ports (printf '%s\n' $all_out | awk -F'\t' '$2 !~ /^monitor/ && $1 != "" {print $1"\t"$3}')

    set -l use_ports
    set -l port_mode
    if test (count $mon_ports) -gt 0
        set use_ports $mon_ports
        set port_mode monitor
    else if test (count $reg_ports) -gt 0
        set use_ports $reg_ports
        set port_mode output
    else
        echo "agent_pw_link_capture: у потока $node_id не найдено выходных портов" >&2
        return 1
    end

    set -l made
    for op in $use_ports
        set -l oid (echo $op | cut -f1)
        set -l och (echo $op | cut -f2)
        # Ищем вход с тем же каналом; если каналы не размечены -- берём по порядку.
        set -l ip_line (printf '%s\n' $in_ports | awk -F'\t' -v c="$och" '$2==c {print $1; exit}' | string collect)
        if test -z "$ip_line"
            set -l k (math (count $made) + 1)
            if test $k -le (count $in_ports)
                set ip_line (echo $in_ports[$k] | cut -f1)
            end
        end
        test -n "$ip_line"; or continue
        if pw-link $oid $ip_line 2>/dev/null
            set -a made "$oid $ip_line"
        end
    end

    if test (count $made) -eq 0
        echo "agent_pw_link_capture: ни одна связь не создалась" >&2
        return 1
    end

    set -l links_json (printf '%s\n' $made | jq -Rc 'split(" ")' | jq -sc '.')
    agent_state_set_json links "$links_json"
    echo $port_mode
end

function agent_pw_unlink_capture
    if not test -f $AUDIO_STATE
        return 0
    end
    set -l pairs (jq -r '.links // [] | .[] | "\(.[0]) \(.[1])"' $AUDIO_STATE 2>/dev/null)
    for p in $pairs
        set -l o (echo $p | cut -d' ' -f1)
        set -l i (echo $p | cut -d' ' -f2)
        pw-link -d $o $i 2>/dev/null
    end
    agent_state_set_json links '[]'
end

function agent_pw_capture_health --description "Одним запросом: <узел жив 1/0> <число живых связей ответвления>"
    set -l node_id (agent_audio_state_get node_id | string collect)
    if test -z "$node_id" -o ! -f $AUDIO_STATE
        echo "0 0"
        return 0
    end
    # Сравнивать надо ПАРУ портов, а не один выходной: выходной порт приложения
    # кормит одновременно и физическое устройство, и agent-capture. Если
    # сравнивать только его, оборванное ответвление выглядит живым, потому что
    # связь с наушниками никуда не делась.
    set -l out (pw-dump 2>/dev/null | jq -r --argjson nid "$node_id" --slurpfile s $AUDIO_STATE '
        (if any(.[]; .type == "PipeWire:Interface:Node" and .id == $nid) then 1 else 0 end) as $alive
        | [ .[] | select(.type == "PipeWire:Interface:Link")
            | "\((.info["output-port-id"] // .info["output_port_id"]))->\((.info["input-port-id"] // .info["input_port_id"]))" ] as $cur
        | ([ ($s[0].links // [])[] | select(("\(.[0])->\(.[1])") as $k | ($cur | index($k)) != null) ] | length) as $n
        | "\($alive) \($n)"' 2>/dev/null | string collect)
    if test -z "$out"
        echo "0 0"
    else
        echo $out
    end
end

function agent_pw_node_alive --argument-names node_id
    test -n "$node_id"; or return 1
    pw-dump 2>/dev/null | jq -r --argjson nid "$node_id" '
        .[] | select(.type == "PipeWire:Interface:Node") | select(.id == $nid) | .id' | head -n1
end

function agent_pw_links_alive --description "Сколько сохранённых связей реально существует в графе"
    if not test -f $AUDIO_STATE
        echo 0
        return 0
    end
    set -l want (jq -r '.links // [] | length' $AUDIO_STATE 2>/dev/null | string collect)
    if test -z "$want" -o "$want" = "0"
        echo 0
        return 0
    end
    set -l have (pw-dump 2>/dev/null | jq -r --slurpfile s $AUDIO_STATE '
        [ .[]
          | select(.type == "PipeWire:Interface:Link")
          | "\((.info["output-port-id"] // .info["output_port_id"]))->\((.info["input-port-id"] // .info["input_port_id"]))"
        ] as $cur
        | [ ($s[0].links // [])[] | select(("\(.[0])->\(.[1])") as $k | ($cur | index($k)) != null) ] | length' 2>/dev/null | string collect)
    if test -z "$have"
        echo "?"
    else
        echo $have
    end
end

# ==========================================================================
# ТИХИЙ РЕЖИМ (работает в режиме link)
# ==========================================================================
#
# Задача: перестать слышать источник, но чтобы агент продолжал слышать его
# полностью. Мониторных портов у потоков Firefox нет (проверено живьём на
# PipeWire 1.6.8), поэтому mute самого потока не подходит -- он обнуляет
# сэмплы до точки ответвления.
#
# Решение: на время тишины отправляем поток целиком в agent-capture, то есть
# убираем у него связь с физическим устройством. Звук никуда не выходит, но в
# agent-capture приходит в полном объёме. Возврат -- обратный перенос плюс
# восстановление ответвления, потому что смена цели у потока пересоздаёт его
# связи и наше ручное ответвление при этом теряется.
#
# Делается через pactl move-sink-input, а не через ручное разрывание связей
# в графе: перенос -- штатная операция, и WirePlumber её уважает, тогда как
# оборванную вручную связь он может восстановить обратно сам.

function agent_stream_current_sink --argument-names serial --description "Имя устройства, куда сейчас играет поток"
    test -n "$serial"; or return 1
    set -l idx (pactl -f json list sink-inputs 2>/dev/null | jq -r --arg i "$serial" '.[] | select((.index|tostring)==$i) | .sink' | head -n1 | string collect)
    agent_sink_name_by_index "$idx"
end

function agent_silenced
    test -f $AUDIO_STATE; or return 1
    set -l v (agent_audio_state_get silenced | string collect)
    test "$v" = "true"
end

function agent_silence_on
    set -l serial (agent_audio_state_get serial | string collect)
    if test -z "$serial"
        return 1
    end
    if agent_silenced
        return 2
    end
    set -l cur (agent_stream_current_sink "$serial" | string collect)
    if test -z "$cur" -o "$cur" = "$AGENT_SINK"
        set cur (agent_default_sink | string collect)
    end
    pactl move-sink-input $serial $AGENT_SINK; or return 1
    agent_state_set silenced true silence_return_sink "$cur"
end

function agent_silence_off
    set -l serial (agent_audio_state_get serial | string collect)
    set -l back (agent_audio_state_get silence_return_sink | string collect)
    if test -z "$serial"
        return 1
    end
    if test -z "$back"
        set back (agent_default_sink | string collect)
    end
    pactl move-sink-input $serial "$back"; or return 1
    # Перенос пересоздал связи потока, поэтому ответвление на агента поднимаем
    # заново. Сначала снимаем записанные ранее связи: часть из них могла
    # пережить перенос, и повторный pw-link по ним просто вернул бы ошибку.
    agent_pw_unlink_capture >/dev/null 2>&1
    set -l node_id (agent_audio_state_get node_id | string collect)
    if test -n "$node_id"
        set -l pm (agent_pw_link_capture $node_id | string collect)
        if test -n "$pm"
            agent_state_set port_mode "$pm"
        end
    end
    agent_state_set silenced false
end

# ==========================================================================
# РЕЖИМ move: петля прослушивания AGENT-MONITOR (запасной путь)
# ==========================================================================

function agent_loopback_module_id
    pactl list modules short | awk -F'\t' '$2=="module-loopback" && $3 ~ /agent-capture\.monitor/ {print $1}' | head -n1
end

function agent_loopback_sink_input_id
    set -l mod (agent_loopback_module_id | string collect)
    pactl -f json list sink-inputs 2>/dev/null | jq -r --arg tag "$AGENT_MONITOR_TAG" --arg mod "$mod" '
        .[]
        | select(
            ((.properties["media.name"] // "") == $tag)
            or (($mod != "") and (((.owner_module // .module // "") | tostring) == $mod))
            or (((.properties["application.name"] // "") | test("loopback"; "i")))
          )
        | .index' | head -n1
end

function agent_loopback_create --argument-names target_sink
    if test -z "$target_sink"
        set target_sink (agent_default_sink | string collect)
    end
    pactl load-module module-loopback \
        source=$AGENT_MONITOR sink="$target_sink" latency_msec=$LOOPBACK_LATENCY \
        sink_input_properties=media.name=$AGENT_MONITOR_TAG >/dev/null 2>&1
    if test $status -ne 0
        pactl load-module module-loopback \
            source=$AGENT_MONITOR sink="$target_sink" latency_msec=$LOOPBACK_LATENCY >/dev/null 2>&1
    end
end

function agent_loopback_ensure --argument-names target_sink
    set -l mod (agent_loopback_module_id | string collect)
    if test -z "$mod"
        agent_loopback_create "$target_sink"
        return 0
    end
    if test -n "$target_sink"
        agent_loopback_move "$target_sink"
    end
end

function agent_loopback_move --argument-names target_sink
    test -n "$target_sink"; or return 1
    set -l si (agent_loopback_sink_input_id | string collect)
    if test -z "$si"
        agent_loopback_create "$target_sink"
        return $status
    end
    pactl move-sink-input $si "$target_sink"
end

function agent_loopback_target
    set -l si (agent_loopback_sink_input_id | string collect)
    test -n "$si"; or return 1
    set -l sink_idx (pactl -f json list sink-inputs | jq -r --arg i "$si" '.[] | select((.index|tostring)==$i) | .sink' | head -n1 | string collect)
    agent_sink_name_by_index "$sink_idx"
end

function agent_loopback_muted
    set -l si (agent_loopback_sink_input_id | string collect)
    test -n "$si"; or return 1
    pactl -f json list sink-inputs | jq -r --arg i "$si" '.[] | select((.index|tostring)==$i) | .mute' | head -n1
end

function agent_loopback_volume
    set -l si (agent_loopback_sink_input_id | string collect)
    test -n "$si"; or return 1
    pactl -f json list sink-inputs | jq -r --arg i "$si" '
        .[] | select((.index|tostring)==$i) | .volume | to_entries[0].value.value_percent' | head -n1
end

function agent_loopback_set_mute --argument-names mode
    set -l si (agent_loopback_sink_input_id | string collect)
    test -n "$si"; or return 1
    pactl set-sink-input-mute $si $mode
end

function agent_loopback_set_volume --argument-names pct
    set -l si (agent_loopback_sink_input_id | string collect)
    test -n "$si"; or return 1
    pactl set-sink-input-volume $si $pct%
end

function agent_loopback_destroy
    set -l mod (agent_loopback_module_id | string collect)
    if test -n "$mod"
        pactl unload-module $mod
    end
end

# ==========================================================================
# Общее для обоих режимов
# ==========================================================================

function agent_capture_alive --description "Непусто, если захваченный поток ещё существует"
    set -l mode (agent_audio_state_get mode | string collect)
    switch "$mode"
        case link
            agent_pw_node_alive (agent_audio_state_get node_id | string collect)
        case move
            set -l si (agent_audio_state_get captured_sink_input | string collect)
            test -n "$si"; or return 1
            pactl -f json list sink-inputs 2>/dev/null | jq -r --arg i "$si" '.[] | select((.index|tostring)==$i) | .index' | head -n1
        case '*'
            return 1
    end
end

function agent_capture_release --description "Снять захват, вернув всё как было"
    set -l mode (agent_audio_state_get mode | string collect)
    switch "$mode"
        case link
            # Если оставить сессию в тихом режиме, поток так и останется
            # приписанным к agent-capture, и WirePlumber запомнит это как
            # предпочтение приложения. Поэтому сначала возвращаем звук.
            if agent_silenced
                set -l serial (agent_audio_state_get serial | string collect)
                set -l back (agent_audio_state_get silence_return_sink | string collect)
                if test -n "$serial" -a -n "$back"
                    pactl move-sink-input $serial "$back" 2>/dev/null
                end
            end
            agent_pw_unlink_capture
        case move
            set -l si (agent_audio_state_get captured_sink_input | string collect)
            set -l orig (agent_audio_state_get original_sink | string collect)
            if test -n "$si" -a -n "$orig"
                pactl move-sink-input $si "$orig" 2>/dev/null
            end
            agent_loopback_destroy
    end
    agent_state_clear
end
