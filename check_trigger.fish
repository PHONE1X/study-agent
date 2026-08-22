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
    # Приводим к нижнему регистру здесь, а сравниваемый текст -- в check_trigger.
    # Флаг -i у string match НЕ складывает регистр кириллицы в этой сборке fish:
    # проверено, «как» не совпадает с «Как». Из-за этого имя, записанное с
    # маленькой буквы («ну артур же говорил»), не срабатывало вообще.
    string join '|' (string lower -- $words)
end

function check_trigger --argument-names text
    set -l pattern (build_trigger_pattern)
    string match -q -r -- $pattern (string lower -- $text)
end


# --- вопросы ко всей группе ------------------------------------------------
#
# Отдельно от имени: «как ваше настроение?» адресовано всем, имя не звучит,
# и раньше такое просто проходило мимо. Условий два сразу -- знак вопроса И
# признак обращения к аудитории. Одного знака вопроса мало: на обучении
# вопросы звучат постоянно, и уведомление на каждый было бы шумом.

set -g GROUP_PATTERNS_FILE (dirname (status --current-filename))/group_patterns.txt

function build_group_pattern
    test -f $GROUP_PATTERNS_FILE; or return 1
    set -l pats (cat $GROUP_PATTERNS_FILE | string trim | string match -rv '^\s*(#.*)?$')
    test (count $pats) -gt 0; or return 1
    string join '|' $pats
end

# Вопросительное слово рядом со знаком вопроса -- страховка сверх списка
# фраз в group_patterns.txt. Список конечен, а формулировок у преподавателя
# бесконечно много: живой пример 2026-08-21 -- «Что клиент оценивает в
# разговоре раньше -- содержание информации или манеру общения?» не задело ни
# одну фразу из списка, и уведомление не пришло вовсе.
#
# «потому что» / «так что» исключены явно (отрицательный lookbehind): это
# союз, а не вопросительное «что» -- без исключения сработало бы почти на
# любом сложноподчинённом предложении, где «?» стоит где-то дальше по тексту.
#
# \b тут писать нельзя: в этой сборке PCRE2 (без UCP) граница слова не видит
# кириллицу вообще, \bкак\b не матчит даже «как дела» -- проверено отдельно.
# Из-за этого фраза может задеть слово внутри другого слова (например «как»
# в «как-то»), но это разумная цена за то, чтобы не собирать русскую
# морфологию вручную.
set -g GROUP_QUESTION_WORD_RE '(?<!потому )(?<!так )(что|как|почему|зачем|когда|где|сколько|кто|куда|откуда|какой|какая|какое|какие)[^.!?]{0,150}\?'

function check_group_question --argument-names text
    string match -q '*?*' -- $text; or return 1
    set -l lower (string lower -- $text | string collect)
    set -l pattern (build_group_pattern)
    if test -n "$pattern"; and string match -q -r -- $pattern $lower
        return 0
    end
    string match -q -r -- $GROUP_QUESTION_WORD_RE $lower
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
        "Артём спросил про артефакты|0" \
        "ну иван же это уже настраивал|1"

    set -l gtests \
        "Хочу задать вам вопрос, как ваше настроение?|1" \
        "Ребят, у кого-то есть вопросы по платформе?|1" \
        "Как вы думаете, сколько это занимает?|1" \
        "Коллеги, всем слышно меня?|0" \
        "Сейчас разберём следующий раздел.|0" \
        "А ты уже настроил себе почту?|0" \
        "Это работает через API, да?|0" \
        "Что клиент оценивает в разговоре раньше — содержание информации или манеру общения?|1" \
        "Хорошо, а как считаете, кто клиент оценивает в разговоре раньше содержание информации или манеру общения?|1" \
        "Кто хотел сказать? Артур или Влад?|1" \
        "Всем все понятно?|0" \
        "Это нашли, ребят, нет у себя?|0" \
        "Дошло, ребята? Да, я открыл|0" \
        "Потому что это важно, вы согласны?|0" \
        "Так что вы решили?|0" \
        "Видите, у себя открыли, да?|0"

    for t in $gtests
        set -l parts (string split '|' $t)
        set -l got 0
        if check_group_question $parts[1]
            set got 1
        end
        if test "$got" = "$parts[2]"
            echo "OK:   [группа] $parts[1] -> $got"
            set pass (math $pass + 1)
        else
            echo "FAIL: [группа] $parts[1] -> $got (expected $parts[2])"
            set fail (math $fail + 1)
        end
    end

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
