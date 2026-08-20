#!/usr/bin/env fish
# Единая точка управления учебным агентом.
#
#   agent                  -- интерактивное меню
#   agent start            -- старт сессии + выбор источника
#   agent stop             -- стоп сессии, захват снимается
#   agent status           -- что происходит прямо сейчас
#   agent source           -- сменить захватываемый источник
#   agent source --move    -- то же, но старым режимом переноса потока
#   agent mute / unmute    -- заглушить / вернуть звук у себя
#   agent out [устр.]      -- (режим move) куда выводить звук агента
#   agent vol <0-150>      -- (режим move) громкость прослушивания
#   agent interval [сек]   -- как часто пишутся заметки
#   agent reset            -- новая чистая сессия заметок
#   agent restart          -- перезапустить сервисы после правки кода
#   agent watch            -- живой транскрипт текущей сессии в терминале
#   agent logs t|h|c       -- логи
#   agent model [имя]      -- посмотреть или сменить модель
#   agent stop --all       -- стоп + выгрузить и whisper-server
#   agent asks [N]         -- последние обращения к тебе
#   agent summary          -- собрать итоговый конспект сессии
#   agent notes            -- где лежат заметки
#   agent probe            -- диагностический дамп аудиографа

source (dirname (status --current-filename))/sa_config.fish
set -g SA_DIR (dirname (status --current-filename))
source $SA_DIR/audio_lib.fish
source $SA_DIR/sa_common.fish

set -g SVC_TRANSCRIBE study-agent-transcribe.service
set -g SVC_HOT study-agent-hotpath.service
set -g SVC_COLD study-agent-coldpath.service
set -g SVC_WATCH study-agent-audiowatch.service
set -g SVC_MIRROR study-agent-mirror.service
set -g SVC_WHISPER whisper-server.service
set -g COLD_STATE ~/.local/share/study-agent/cold_path_state.json
set -g TRANSCRIPT ~/.local/share/study-agent/transcript.log
set -g INTERVAL_FILE ~/.local/share/study-agent/interval
set -g ASKS_FILE ~/.local/share/study-agent/asks.jsonl
set -g STUDY_DIR $SA_STUDY_DIR

# --- статус ---------------------------------------------------------------

function sa_svc_line --argument-names label unit
    set -l st (systemctl --user is-active $unit 2>/dev/null | string collect)
    if test -z "$st"
        set st "нет юнита"
    end
    switch $st
        case active
            echo "  $label: работает"
        case inactive
            echo "  $label: остановлен"
        case failed
            echo "  $label: ОШИБКА (смотри логи)"
        case '*'
            echo "  $label: $st"
    end
end

function sa_status
    echo "==== УЧЕБНЫЙ АГЕНТ ===="
    echo ""
    echo "СЕРВИСЫ"
    sa_svc_line "распознавание речи" $SVC_TRANSCRIBE
    sa_svc_line "горячий путь      " $SVC_HOT
    sa_svc_line "холодный путь     " $SVC_COLD
    sa_svc_line "зеркало транскрипта" $SVC_MIRROR
    sa_svc_line "сторож ответвления" $SVC_WATCH
    sa_svc_line "whisper-server    " $SVC_WHISPER
    if curl -s -m 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1
        set -l m (sa_model | string collect)
        set -l loaded (sa_model_loaded)
        if contains -- $m $loaded
            echo "  языковая модель   : $m, в видеопамяти"
        else
            echo "  языковая модель   : $m, выгружена (поднимется по первому запросу)"
        end
    else
        echo "  языковая модель   : НЕ ОТВЕЧАЕТ (Ollama не запущена)"
    end

    echo ""
    echo "ЗАХВАТ ЗВУКА"
    set -l sink_id (agent_sink_id | string collect)
    set -l mode (agent_audio_state_get mode | string collect)
    if test -z "$sink_id"
        echo "  виртуальное устройство $AGENT_SINK не создано"
    else if test -z "$mode"
        echo "  источник не выбран — запусти: agent source"
    else
        set -l app (agent_audio_state_get app | string collect)
        set -l media (agent_audio_state_get media | string collect)
        set -l alive (agent_capture_alive | string collect)
        if test -z "$alive"
            echo "  ВНИМАНИЕ: захваченный поток исчез (вкладка закрыта или звук кончился)."
            echo "  Записывается тишина. Выбери источник заново: agent source"
            echo "  Был: $app — $media"
        else
            echo "  источник: $app — $media"
        end

        if test "$mode" = link
            if agent_silenced
                set -l back (agent_audio_state_get silence_return_sink | string collect)
                set -l bdesc (agent_sink_description "$back" | string collect)
                echo "  режим: ТИХИЙ — звук идёт только агенту, наружу не выводится"
                echo "  вернуть звук на «$bdesc»: agent unmute"
            else
                set -l pm (agent_audio_state_get port_mode | string collect)
                set -l nl (agent_pw_links_alive | string collect)
                echo "  режим: ответвление копии (устройство приложения не тронуто)"
                echo "  живых связей в графе: $nl"
                if test "$pm" = monitor
                    echo "  порты: monitor — можно глушить приложение, запись не пострадает"
                else
                    echo "  порты: output — глушить приложение нельзя, вместо этого: agent mute"
                end
            end
        else
            echo "  режим: перенос потока в $AGENT_SINK"
        end
    end

    if test "$mode" = move
        echo ""
        echo "ПРОСЛУШИВАНИЕ (петля AGENT-MONITOR)"
        set -l loop_si (agent_loopback_sink_input_id | string collect)
        if test -z "$loop_si"
            echo "  выключено — ты не слышишь захватываемый звук"
        else
            set -l tgt (agent_loopback_target | string collect)
            set -l muted (agent_loopback_muted | string collect)
            set -l vol (agent_loopback_volume | string collect)
            set -l tgt_desc (agent_sink_description "$tgt" | string collect)
            echo "  устройство: $tgt_desc"
            if test "$muted" = "true"
                echo "  звук: ЗАГЛУШЕН (захват при этом идёт нормально)"
            else
                echo "  звук: включён"
            end
            if test -n "$vol"
                echo "  громкость: $vol"
            end
        end
    end

    echo ""
    echo "ДАННЫЕ"
    if test -f $TRANSCRIPT
        set -l n (wc -l < $TRANSCRIPT | string trim)
        echo "  транскрипт: $n строк"
    else
        echo "  транскрипт: файла ещё нет"
    end
    echo "  интервал заметок: "(sa_interval_get | string collect)" сек"
    if test -f $COLD_STATE
        set -l sess (jq -r '.session_dir // empty' $COLD_STATE | string collect)
        set -l seg (jq -r '.segment_num // 0' $COLD_STATE | string collect)
        if test -n "$sess"
            echo "  сессия заметок: $sess (сегментов: $seg)"
            # Показываем состояние самой папки, а не только запись в state.
            # Раньше state мог бодро рапортовать о четырёх сегментах, пока в
            # вольте не было вообще ничего: папку удалили, а демон продолжал
            # писать по несуществующему пути.
            if test -d "$STUDY_DIR/$sess"
                set -l files (ls -1t "$STUDY_DIR/$sess" 2>/dev/null)
                if test (count $files) -gt 0
                    set -l newest "$STUDY_DIR/$sess/$files[1]"
                    echo "  файлов в папке: "(count $files)", последняя запись: "(date -r "$newest" "+%H:%M:%S" | string collect)
                else
                    echo "  файлов в папке: 0 — заметок ещё нет"
                end
            else
                echo "  ВНИМАНИЕ: папки сессии нет — $STUDY_DIR/$sess"
                echo "  Демон восстановит её на следующем цикле как новую сессию."
            end
        else
            echo "  сессия заметок: ещё не начата"
        end
    else
        echo "  сессия заметок: ещё не начата"
    end
end

# --- интервал заметок -----------------------------------------------------

function sa_interval_get
    if test -f $INTERVAL_FILE
        set -l v (cat $INTERVAL_FILE | string trim | string collect)
        if string match -qr '^\d+$' -- "$v"
            echo $v
            return 0
        end
    end
    echo 120
end

function sa_interval --argument-names secs
    if test -z "$secs"
        echo "Сейчас: "(sa_interval_get | string collect)" сек"
        echo ""
        echo "  60-120  — для теста, заметки появляются быстро"
        echo "  300     — по умолчанию, разумный баланс"
        echo "  600     — длинные лекции, меньше нагрузки на видеокарту"
        echo ""
        read -P "Новое значение в секундах (Enter — оставить): " secs
        if test -z "$secs"
            return 0
        end
    end
    if not string match -qr '^\d+$' -- $secs
        echo "Нужно целое число секунд."
        return 1
    end
    if test "$secs" -lt 30
        echo "Меньше 30 секунд смысла не имеет: на цикл уходит два запроса к модели."
        return 1
    end
    mkdir -p (dirname $INTERVAL_FILE)
    echo $secs > $INTERVAL_FILE
    echo "Интервал заметок: $secs сек. Применится со следующего цикла, перезапуск не нужен."
end

# --- управление сессией ---------------------------------------------------

function sa_session_prime_new --description "Начать новую сессию заметок, не трогая заметки прошлой"
    # Отличие от reset_session.fish: тот УНОСИТ папку прошлой сессии в
    # _to_delete. Для «просто следующего видео» это перебор -- прошлые заметки
    # должны остаться на месте. Здесь только сдвигаем счётчик на конец
    # transcript.log и убираем session_dir: холодный путь увидит, что открытой
    # сессии нет, и заведёт новую папку, пропустив весь старый материал.
    set -l total 0
    if test -f $TRANSCRIPT
        set total (wc -l < $TRANSCRIPT | string trim)
    end
    jq -n --argjson last $total '{last_line: $last}' > $COLD_STATE
end

function sa_start
    # Сессию выбираем ДО запуска сервисов. Раньше выбора не было вовсе:
    # cold_path_state.json переживал stop/start, поэтому новое видео молча
    # дописывалось в папку прошлого -- с чужим названием курса и чужими
    # сегментами. В Obsidian это выглядело так, будто агент не сделал ничего:
    # новой заметки не появлялось, а рост старой в глаза не бросается.
    set -l mode ""
    if contains -- --new $argv
        set mode new
    else if contains -- --continue $argv
        set mode continue
    end

    set -l prev ""
    if test -f $COLD_STATE
        set prev (jq -r '.session_dir // empty' $COLD_STATE | string collect)
    end

    if test -z "$mode"
        if test -n "$prev"
            echo "Прошлая сессия заметок: $prev"
            echo ""
            echo "  1) новая сессия — заведётся новая папка, прошлая останется на месте"
            echo "  2) продолжить прошлую — новый материал допишется в неё же"
            echo ""
            read -l -P "Что делаем? [1] " ans
            switch "$ans"
                case 2 c continue п продолжить
                    set mode continue
                case '*'
                    set mode new
            end
        else
            set mode new
        end
    end

    if test "$mode" = continue
        echo "Продолжаю сессию «$prev»."
    else
        sa_session_prime_new
        if test -n "$prev"
            echo "Начинаю новую сессию. Заметки «$prev» остаются на месте."
        else
            echo "Начинаю новую сессию."
        end
    end

    systemctl --user start $SVC_WHISPER 2>/dev/null
    systemctl --user start $SVC_TRANSCRIBE $SVC_HOT $SVC_COLD $SVC_MIRROR $SVC_WATCH
    # Модель поднимаем в видеопамять заранее, в фоне. Иначе первый же вопрос
    # ждёт загрузку 5+ ГБ, и обещанные несколько секунд превращаются в минуту.
    fish -c "source $SA_DIR/sa_common.fish; sa_model_warm" >/dev/null 2>&1 &
    disown
    sleep 1
    $SA_DIR/route_to_capture.fish
end

function sa_model_cmd --argument-names name
    if test -z "$name"
        set -l cur (sa_model | string collect)
        echo "Модель агента: $cur"
        echo ""
        set -l loaded (sa_model_loaded)
        if test (count $loaded) -gt 0
            echo "Сейчас в видеопамяти: $loaded"
        else
            echo "Сейчас в видеопамяти: ничего"
        end
        echo ""
        if command -q ollama
            echo "Установленные модели:"
            ollama list 2>/dev/null | tail -n +2 | awk '{print "  " $1 "  " $3 $4}'
        end
        echo ""
        echo "Сменить:  agent model <имя>"
        echo "Сравнить на одном материале, не меняя основную:"
        echo "          agent summary --model <имя>"
        return 0
    end
    sa_model_set $name
    echo "Модель агента: $name"
    echo "Применится к новым запросам. Демоны читают настройку при каждом запросе,"
    echo "но горячий путь держит её с момента старта — надёжнее: agent restart"
end

function sa_asks --argument-names n
    if test -z "$n"
        set n 10
    end
    if not test -f $ASKS_FILE
        echo "Обращений пока не было."
        return 0
    end
    echo "Последние обращения к тебе:"
    echo ""
    tail -n $n $ASKS_FILE | jq -r '"[\(.ts)] \(.type): \(.question)" + (if (.answer // "") == "" then "" else "\n    -> \(.answer)" end) + "\n"'
end

function sa_summary
    echo "Собираю итоговый конспект. Это занимает до минуты — модель читает всю сессию."
    $SA_DIR/make_summary.fish $argv
end

function sa_stop
    set -l also_whisper false
    if contains -- --all $argv
        set also_whisper true
    end

    systemctl --user stop $SVC_TRANSCRIBE $SVC_HOT $SVC_COLD $SVC_MIRROR $SVC_WATCH
    agent_capture_release
    echo "Сессия остановлена. Захват снят, звук приложения не тронут."

    # Сегмент, который был открыт на момент остановки, никогда не получает
    # обычного «закрывающего» перехода (следующего сегмента, который бы его
    # закрыл, не будет) -- поэтому сворачиваем его в связное описание здесь.
    if test -f $COLD_STATE
        set -l seg_dir (jq -r '.session_dir // empty' $COLD_STATE | string collect)
        set -l seg_num (jq -r '.segment_num // 0' $COLD_STATE)
        set -l seg_title (jq -r '.segment_title // empty' $COLD_STATE | string collect)
        set -l seg_file (jq -r '.segment_file // empty' $COLD_STATE | string collect)
        set -l seg_course (jq -r '.course_title // empty' $COLD_STATE | string collect)
        if test "$seg_num" -gt 0 -a -n "$seg_dir" -a -n "$seg_file"
            echo "Сворачиваю последний сегмент («$seg_title») в связное описание..."
            fish $SA_DIR/finalize_segment.fish "$STUDY_DIR/$seg_dir/$seg_file" "$seg_title" "$seg_course"
        end
    end

    # Конспект собираем ДО выгрузки модели: он сам её и использует.
    echo ""
    sa_summary

    echo ""
    set -l m (sa_model | string collect)
    sa_model_unload
    echo "Модель $m выгружена из видеопамяти (около 5 ГБ освободилось)."

    if test "$also_whisper" = true
        systemctl --user stop $SVC_WHISPER
        echo "whisper-server остановлен — освободился ещё примерно 1 ГБ."
    else
        echo "whisper-server оставлен работать. Чтобы остановить и его: agent stop --all"
    end
end

function sa_restart
    systemctl --user restart $SVC_TRANSCRIBE $SVC_HOT $SVC_COLD $SVC_MIRROR $SVC_WATCH
    echo "Сервисы перезапущены — свежий код скриптов загружен."
end

function sa_reset
    $SA_DIR/reset_session.fish
    set -l st (systemctl --user is-active $SVC_COLD 2>/dev/null | string collect)
    if test "$st" = "active"
        systemctl --user restart $SVC_COLD
        echo "Холодный путь перезапущен — следующая сессия заметок будет чистой."
    end
end

# --- звук -----------------------------------------------------------------

function sa_glossary --description "Словарь терминов занятия для распознавания"
    # Правится прямо во время занятия: transcribe_stream перечитывает файл по
    # mtime, поэтому дописанный термин начинает действовать со следующего окна.
    # Перезапуск не нужен -- это единственная настройка агента, которая так
    # умеет, и сделано это намеренно: коверканье слышно только на ходу.
    set -l f ~/.config/study-agent/glossary.txt
    if not test -f $f
        mkdir -p (dirname $f)
        cp $SA_DIR/glossary.example.txt $f
        echo "Создал словарь из образца: $f"
    end
    if test (count $argv) -gt 0
        # agent glossary СЛОВО -- быстро дописать термин, не открывая редактор.
        for w in $argv
            echo $w >> $f
            echo "Добавлено: $w"
        end
        echo "Подействует со следующего окна распознавания (до 30 секунд)."
        return 0
    end
    echo "Словарь: $f"
    echo ""
    grep -v '^\s*#' $f | string match -rv '^\s*$'
    echo ""
    echo "Дописать термин:  agent glossary «слово»"
    echo "Открыть целиком:  \$EDITOR $f"
end

function sa_watch --description "Живой просмотр транскрипта текущей сессии"
    # Зачем отдельная команда. Obsidian перечитывает файл, изменённый снаружи,
    # когда окно получает фокус. Во время созвона оно свёрнуто, и заметка
    # выглядит застывшей, хотя строки в неё пишутся каждые несколько секунд.
    # Здесь видно сразу и без фокуса -- это самый быстрый способ убедиться,
    # что захват жив.
    set -l d ""
    if test -f $COLD_STATE
        set d (jq -r '.session_dir // empty' $COLD_STATE | string collect)
    end
    if test -z "$d"
        echo "Сессия ещё не заведена — смотреть нечего."
        echo "Пока можно следить за сырым транскриптом:"
        echo "  tail -F ~/.local/share/study-agent/transcript.log"
        return 1
    end
    set -l path "$STUDY_DIR/$d/Транскрипт.md"
    if not test -f "$path"
        echo "Файл транскрипта ещё не создан: $path"
        return 1
    end
    echo "Сессия: $d"
    echo "Файл:   $path"
    echo "Ctrl+C — выйти. Ниже появляются строки по мере распознавания."
    echo ""
    tail -n 5 -F "$path"
end

function sa_mute
    set -l mode (agent_audio_state_get mode | string collect)
    if test "$mode" = link
        set -l app (agent_audio_state_get app | string collect)
        agent_silence_on
        switch $status
            case 0
                echo "Тихий режим включён."
                echo "Звук «$app» больше никуда не выводится, но агент слышит его полностью."
                echo "Вернуть звук: agent unmute"
            case 2
                echo "Тихий режим уже включён."
            case '*'
                echo "Не получилось включить тихий режим. Проверь: agent status"
                return 1
        end
        return 0
    end
    agent_loopback_ensure ""
    if agent_loopback_set_mute 1
        echo "Заглушено. Ты не слышишь захватываемый звук, агент слышит его по-прежнему."
    else
        echo "Петли прослушивания нет — слышать и так нечего."
    end
end

function sa_unmute
    set -l mode (agent_audio_state_get mode | string collect)
    if test "$mode" = link
        if not agent_silenced
            echo "Тихий режим и так выключен."
            return 0
        end
        if agent_silence_off
            set -l back (agent_audio_state_get silence_return_sink | string collect)
            set -l desc (agent_sink_description "$back" | string collect)
            echo "Звук вернулся на: $desc"
        else
            echo "Не получилось вернуть звук. Проверь: agent status"
            return 1
        end
        return 0
    end
    agent_loopback_ensure ""
    if agent_loopback_set_mute 0
        echo "Звук снова слышно."
    else
        echo "Не удалось найти петлю прослушивания. Попробуй: agent out"
    end
end

function sa_toggle
    set -l mode (agent_audio_state_get mode | string collect)
    if test "$mode" = link
        if agent_silenced
            sa_unmute
        else
            sa_mute
        end
        return 0
    end
    set -l muted (agent_loopback_muted | string collect)
    if test "$muted" = "true"
        sa_unmute
    else
        sa_mute
    end
end

function sa_out
    set -l mode (agent_audio_state_get mode | string collect)
    if test "$mode" = link
        echo "В этом режиме устройством вывода управляет само приложение."
        echo "Меняй его как обычно — в pavucontrol у строки приложения. На захват"
        echo "это не влияет: копия сигнала ответвляется до устройства вывода."
        return 0
    end
    set -l target $argv[1]
    if test -z "$target"
        set -l sinks (agent_real_sinks)
        if test (count $sinks) -eq 0
            echo "Не найдено ни одного устройства вывода."
            return 1
        end
        set -l cur (agent_loopback_target | string collect)
        echo "Куда выводить звук агента?"
        echo ""
        for i in (seq (count $sinks))
            set -l mark ""
            if test "$sinks[$i]" = "$cur"
                set mark "   <- сейчас"
            end
            set -l desc (agent_sink_description $sinks[$i] | string collect)
            echo "  $i) $desc$mark"
        end
        echo "  0) Никуда — полностью убрать прослушивание"
        echo ""
        read -P "Номер: " c
        if test "$c" = "0"
            agent_loopback_destroy
            echo "Прослушивание убрано. Захват и конспектирование продолжаются."
            return 0
        end
        if not string match -qr '^\d+$' -- $c
            echo "Некорректный ввод."
            return 1
        end
        if test "$c" -lt 1 -o "$c" -gt (count $sinks)
            echo "Некорректный ввод."
            return 1
        end
        set target $sinks[$c]
    end
    agent_loopback_ensure "$target"
    agent_loopback_move "$target"
    set -l desc (agent_sink_description "$target" | string collect)
    echo "Звук агента выводится на: $desc"
end

function sa_vol --argument-names pct
    set -l mode (agent_audio_state_get mode | string collect)
    if test "$mode" = link
        echo "В этом режиме громкостью управляет само приложение."
        echo "Важно: громкость в PipeWire (pavucontrol) при мониторных портах на"
        echo "запись не влияет, а громкость внутри плеера — влияет."
        return 0
    end
    if test -z "$pct"
        read -P "Громкость прослушивания в процентах (0-150): " pct
    end
    if not string match -qr '^\d+$' -- $pct
        echo "Нужно число от 0 до 150."
        return 1
    end
    if agent_loopback_set_volume $pct
        echo "Громкость прослушивания: $pct%. На запись это не влияет."
    else
        echo "Петли прослушивания нет. Сначала: agent out"
    end
end

# --- диагностика ----------------------------------------------------------

function sa_probe
    echo "===== ДИАГНОСТИКА АУДИОГРАФА ====="
    echo "дата: "(date -Iseconds)
    echo ""
    echo "--- версии ---"
    pw-cli --version 2>/dev/null | head -n3
    pactl --version 2>/dev/null | head -n1
    echo ""
    echo "--- играющие потоки (Stream/Output/Audio) ---"
    agent_pw_streams
    echo ""
    echo "--- порты каждого потока: id / направление / имя / канал ---"
    for l in (agent_pw_streams)
        set -l nid (echo $l | jq -r '.id')
        set -l app (echo $l | jq -r '.app')
        set -l med (echo $l | jq -r '.media')
        echo "  узел $nid — $app — $med"
        agent_pw_ports $nid | sed 's/^/      /'
    end
    echo ""
    echo "--- узел и порты $AGENT_SINK ---"
    set -l sn (agent_pw_node_id_by_name $AGENT_SINK | string collect)
    echo "  node id: $sn"
    if test -n "$sn"
        agent_pw_ports $sn | sed 's/^/      /'
    end
    echo ""
    echo "--- состояние захвата ---"
    if test -f $AUDIO_STATE
        cat $AUDIO_STATE
    else
        echo "  файла состояния нет"
    end
    echo ""
    echo "--- существующие связи в графе (первые 40) ---"
    pw-link -l 2>/dev/null | head -n 40
    echo "===== КОНЕЦ ====="
end

# --- прочее ---------------------------------------------------------------

function sa_logs --argument-names which
    switch "$which"
        case t transcribe ''
            journalctl --user -u $SVC_TRANSCRIBE -f
        case h hot
            journalctl --user -u $SVC_HOT -f
        case c cold
            journalctl --user -u $SVC_COLD -f
        case m mirror
            journalctl --user -u $SVC_MIRROR -f
        case '*'
            echo "agent logs t|h|c|m  (распознавание | горячий путь | холодный путь | зеркало транскрипта)"
    end
end

function sa_notes
    if not test -f $COLD_STATE
        echo "Сессия заметок ещё не начата."
        return 1
    end
    set -l sess (jq -r '.session_dir // empty' $COLD_STATE | string collect)
    if test -z "$sess"
        echo "Сессия заметок ещё не начата."
        return 1
    end
    echo "Папка сессии: $STUDY_DIR/$sess"
    echo ""
    if not test -d "$STUDY_DIR/$sess"
        echo "Папки нет. Её удалили или перенесли."
        echo "Следующий цикл холодного пути начнёт новую сессию автоматически."
        echo "Чтобы не ждать цикл, начни чистую сессию сразу: agent reset"
        return 1
    end
    ls -1 "$STUDY_DIR/$sess"
end

function sa_help
    echo "agent                — меню"
    echo "agent start          — старт сессии + выбор источника"
    echo "agent stop           — стоп сессии"
    echo "agent status         — что происходит сейчас"
    echo "agent source         — сменить захватываемый источник"
    echo "agent source --move  — то же, запасным режимом переноса потока"
    echo "agent mute           — тихий режим: не слышу, агент слышит"
    echo "agent unmute         — вернуть звук"
    echo "agent out [устр.]    — (режим move) куда выводить звук агента"
    echo "agent vol <0-150>    — (режим move) громкость прослушивания"
    echo "agent interval [сек] — как часто пишутся заметки"
    echo "agent reset          — новая чистая сессия заметок"
    echo "agent restart        — перезапустить сервисы"
    echo "agent watch          — живой транскрипт в терминале"
    echo "agent glossary [сл.] — словарь терминов занятия (без слова — показать)"
    echo "agent logs t|h|c     — логи"
    echo "agent model [имя]    — какая модель используется"
    echo "agent asks [N]       — последние обращения к тебе"
    echo "agent summary        — собрать итоговый конспект сессии"
    echo "agent notes          — где лежат заметки"
    echo "agent probe          — диагностический дамп аудиографа"
end

# --- меню -----------------------------------------------------------------

function sa_menu
    while true
        echo ""
        sa_status
        echo ""
        echo "  1) Старт сессии             5) Тихий режим вкл/выкл"
        echo "  2) Стоп сессии              6) Интервал заметок"
        echo "  3) Сменить источник         7) Новая чистая сессия заметок"
        echo "  4) Устройство вывода        8) Логи"
        echo "  9) Где лежат заметки        s) Собрать итоговый конспект"
        echo "  a) Обращения к тебе"
        echo "  0) Выход"
        echo ""
        read -P "> " c
        switch "$c"
            case 1
                sa_start
            case 2
                sa_stop
            case 3
                $SA_DIR/route_to_capture.fish
            case 4
                sa_out
            case 5
                sa_toggle
            case 6
                sa_interval
            case 7
                sa_reset
            case 8
                echo "  t) распознавание   h) горячий путь   c) холодный путь"
                read -P "> " w
                sa_logs "$w"
            case 9
                sa_notes
            case s
                sa_summary
            case a
                sa_asks
            case 0 q ''
                return 0
            case '*'
                echo "Нет такого пункта."
        end
    end
end

# --- диспетчер ------------------------------------------------------------

switch "$argv[1]"
    case ''
        sa_menu
    case start
        sa_start $argv[2..-1]
    case stop
        sa_stop $argv[2..-1]
    case restart
        sa_restart
    case watch tail follow
        sa_watch
    case glossary gloss словарь
        sa_glossary $argv[2..-1]
    case status st
        sa_status
    case source src
        $SA_DIR/route_to_capture.fish $argv[2..-1]
    case out
        sa_out $argv[2]
    case mute silence quiet
        sa_mute
    case unmute unsilence loud
        sa_unmute
    case toggle
        sa_toggle
    case vol volume
        sa_vol $argv[2]
    case interval
        sa_interval $argv[2]
    case reset
        sa_reset
    case logs log
        sa_logs $argv[2]
    case notes
        sa_notes
    case summary sum
        sa_summary $argv[2..-1]
    case asks ask
        sa_asks $argv[2]
    case model
        sa_model_cmd $argv[2]
    case probe
        sa_probe
    case help --help -h
        sa_help
    case '*'
        echo "Неизвестная команда: $argv[1]"
        echo ""
        sa_help
        exit 1
end
