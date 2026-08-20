#!/usr/bin/env fish

# Свой список имён лежит в trigger_words.txt и в репозиторий не попадает --
# это личные данные. В свежей копии его ещё нет, поэтому откатываемся на
# образец: агент должен запускаться сразу, а не падать на отсутствии файла.
set -g TRIGGER_WORDS_FILE (dirname (status --current-filename))/trigger_words.txt
if not test -f $TRIGGER_WORDS_FILE
    set TRIGGER_WORDS_FILE (dirname (status --current-filename))/trigger_words.example.txt
end

function build_trigger_pattern
    set -l words (cat $TRIGGER_WORDS_FILE | string trim | string match -rv '^\s*(#.*)?$')
    string join '|' $words
end

function check_trigger --argument-names text
    set -l pattern (build_trigger_pattern)
    string match -q -r -i -- $pattern $text
end

if test "$argv[1]" = "--test"
    # Тесты идут по образцу, а не по личному списку: иначе они зависели бы
    # от того, чьё имя вписано в trigger_words.txt.
    set TRIGGER_WORDS_FILE (dirname (status --current-filename))/trigger_words.example.txt
    set -l pass 0
    set -l fail 0
    set -l tests \
        "Иван, как думаешь?|1" \
        "Спросите Ивана|1" \
        "Ивану Иванову|1" \
        "Иванов, ваш комментарий?|1" \
        "Об Иване|1" \
        "Ивановым|1" \
        "Иваном|1" \
        "Обсудим маршрутизацию|0" \
        "Артём спросил про артефакты|0"

    for t in $tests
        set -l parts (string split '|' $t)
        set -l phrase $parts[1]
        set -l expected $parts[2]
        set -l got 0
        if check_trigger $phrase
            set got 1
        end
        if test "$got" = "$expected"
            echo "OK:   $phrase -> $got"
            set pass (math $pass + 1)
        else
            echo "FAIL: $phrase -> $got (expected $expected)"
            set fail (math $fail + 1)
        end
    end
    echo "--- $pass passed, $fail failed ---"
end
