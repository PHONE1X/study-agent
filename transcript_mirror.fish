#!/usr/bin/env fish
# Живое зеркало транскрипта: доливает распознанные строки в Транскрипт.md
# текущей сессии раз в пару секунд.
#
# Зачем отдельный демон. Холодный путь пишет заметки раз в интервал и делает
# это через модель: цикл может думать десятки секунд. Пока он думает, в вольте
# не меняется ничего, и со стороны это выглядит как «агент не работает» --
# особенно в первые минуты, когда конспекта ещё нет по определению. Транскрипт
# же не требует ни модели, ни размышлений: строки уже готовы в transcript.log,
# их достаточно скопировать. Поэтому запись транскрипта вынесена сюда, а
# холодный путь занимается только тем, ради чего нужна модель, -- сегментами и
# конспектом.
#
# Своё состояние, отдельно от cold_path_state.json: демоны пишут независимо и
# перетирали бы файл друг друга. Здесь -- только чтение чужого состояния.

source (dirname (status --current-filename))/sa_config.fish
set -g TRANSCRIPT_FILE ~/.local/share/study-agent/transcript.log
set -g COLD_STATE ~/.local/share/study-agent/cold_path_state.json
set -g MIRROR_STATE ~/.local/share/study-agent/mirror_state.json
set -g STUDY_DIR $SA_STUDY_DIR
set -g POLL_SECONDS 3

function mirror_cycle
    test -f $TRANSCRIPT_FILE; or return 0
    test -f $COLD_STATE; or return 0

    # Папку сессии заводит холодный путь -- он один умеет спросить у модели
    # название темы. Пока её нет, лить некуда: просто ждём.
    set -l session_dir (jq -r '.session_dir // empty' $COLD_STATE | string collect)
    test -n "$session_dir"; or return 0

    set -l session_path "$STUDY_DIR/$session_dir"
    test -d "$session_path"; or return 0

    set -l session_start (jq -r '.session_start_line // 0' $COLD_STATE)

    # С какой строки продолжать.
    set -l mirrored 0
    set -l known_dir ""
    if test -f $MIRROR_STATE
        set known_dir (jq -r '.session_dir // empty' $MIRROR_STATE | string collect)
        set mirrored (jq -r '.last_line // 0' $MIRROR_STATE)
    end

    if test "$known_dir" != "$session_dir"
        # Про эту сессию зеркало ещё ничего не знает: либо она новая, либо
        # своё состояние потерялось. Начинать с session_start_line вслепую
        # нельзя -- если в Транскрипт.md уже что-то лежит, весь этот кусок
        # задвоится. Поэтому считаем позицию по самому файлу: он состоит
        # только из строк транскрипта, значит его длина и есть число уже
        # перенесённых строк. Пересчёт самовосстанавливающийся -- переживает и
        # перезапуск демона, и ручную правку заметки.
        if test "$session_start" -gt 0
            set -l already 0
            if test -f "$session_path/Транскрипт.md"
                set already (wc -l < "$session_path/Транскрипт.md" | string trim)
            end
            set mirrored (math $session_start - 1 + $already)
        else
            # Состояние от старой версии, без session_start_line. Ориентир
            # один -- сколько строк уже разобрал холодный путь.
            set mirrored (jq -r '.last_line // 0' $COLD_STATE)
        end
        if test $mirrored -lt 0
            set mirrored 0
        end
    end

    set -l total (wc -l < $TRANSCRIPT_FILE | string trim)
    if test "$total" -le "$mirrored"
        # Файл мог быть очищен между сессиями -- тогда счётчик надо опустить,
        # иначе зеркало замрёт навсегда, ожидая строку, которой уже не будет.
        if test "$total" -lt "$mirrored"
            jq -n --arg dir "$session_dir" --argjson last $total \
                '{session_dir: $dir, last_line: $last}' > $MIRROR_STATE
        end
        return 0
    end

    set -l from (math $mirrored + 1)
    set -l chunk (sed -n "$from,$total p" $TRANSCRIPT_FILE | string collect)
    if test -z (string trim -- "$chunk" | string collect)
        return 0
    end

    echo "$chunk" >> "$session_path/Транскрипт.md"

    jq -n --arg dir "$session_dir" --argjson last $total \
        '{session_dir: $dir, last_line: $last}' > $MIRROR_STATE

    echo "MIRROR: +"(math $total - $mirrored)" строк -> $session_dir/Транскрипт.md (по строку $total)"
end

if test "$argv[1]" = "--once"
    mirror_cycle
    exit 0
end

echo "Transcript mirror started (poll=$POLL_SECONDS s) -> $STUDY_DIR/<сессия>/Транскрипт.md"
while true
    mirror_cycle
    sleep $POLL_SECONDS
end
