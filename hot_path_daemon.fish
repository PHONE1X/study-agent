#!/usr/bin/env fish
# Горячий путь: следит за новыми строками транскрипта и при появлении
# триггерного слова или вопроса ко всей группе запускает в фоне
# draft_answer.fish, не блокируя дальнейшую детекцию. Уведомление ровно одно
# на срабатывание, и шлёт его draft_answer.fish, уже с вопросом и ответом --
# раньше здесь было ещё одно, мгновенное, но два уведомления подряд по одному
# и тому же поводу выглядели как повтор, и от него отказались (2026-08-21).
#
# Работает рядом с transcribe_stream.py отдельным процессом, читая его вывод --
# проверенный цикл транскрипции при этом не трогается.

set -g STUDY_AGENT_DIR ~/.local/bin/study-agent
set -g TRANSCRIPT_FILE ~/.local/share/study-agent/transcript.log

# Пауза между уведомлениями о вопросах ко всей группе, в секундах.
if not set -q GROUP_COOLDOWN
    set -g GROUP_COOLDOWN 180
end
set -g GROUP_LAST_FILE ~/.local/share/study-agent/group_last

source $STUDY_AGENT_DIR/check_trigger.fish

echo "Hot path watching $TRANSCRIPT_FILE for trigger words..."

tail -n0 -F $TRANSCRIPT_FILE | while read -l line
    # строка вида: [16:47:04] распознанный текст
    set -l ts (string match -r '^\[(\d+:\d+:\d+)\]' -- $line)[2]
    set -l text (string replace -r '^\[\d+:\d+:\d+\]\s*' '' -- $line)

    if check_trigger $text
        # Уведомление тут раньше было своё, мгновенное ("К вам обратились"),
        # а через несколько секунд следом приходило второе от draft_answer.fish
        # с вопросом и ответом. По факту это выглядело как два уведомления
        # почти подряд, и второе легко принять за повтор первого. Отдельное
        # мгновенное здесь убрано -- остаётся одно, от draft_answer.fish, сразу
        # с вопросом и ответом. Плата за это: до появления уведомления теперь
        # проходит вся пауза draft_answer.fish (специально выжидает хвост
        # вопроса) плюс время на два обращения к модели, а не 0 секунд как
        # было для этого шага.
        echo "TRIGGER: $text"
        # Метка времени передаётся отдельно: запись об обращении должна быть
        # помечена моментом, когда это прозвучало, а не когда модель ответила.
        fish $STUDY_AGENT_DIR/draft_answer.fish "$text" "$ts" &
        disown
    else if check_group_question $text
        # Вопрос ко всей группе: имя не звучало, но ответить могут попросить
        # любого. Срочность ниже, чем у личного обращения, -- это не «тебя
        # спросили», а «спросили всех».
        #
        # Кулдаун обязателен. На обучении ведущий спрашивает аудиторию каждые
        # пару минут («всем понятно?», «как ваше настроение?»), и без паузы
        # это превратилось бы в поток уведомлений, который просто отключат.
        set -l now (date +%s)
        set -l last 0
        if test -f $GROUP_LAST_FILE
            set last (cat $GROUP_LAST_FILE 2>/dev/null | string trim)
        end
        if test -z "$last"
            set last 0
        end
        if test (math "$now - $last") -ge $GROUP_COOLDOWN
            echo $now > $GROUP_LAST_FILE
            echo "GROUP: $text"
            fish $STUDY_AGENT_DIR/draft_answer.fish "$text" "$ts" группа &
            disown
        else
            echo "GROUP (кулдаун, пропущено): $text"
        end
    end
end
