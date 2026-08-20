#!/usr/bin/env fish
# Горячий путь: следит за новыми строками транскрипта, мгновенно шлёт
# уведомление при появлении триггерного слова (уведомление №1), затем в фоне
# запускает draft_answer.fish для черновика ответа (уведомление №2), не
# блокируя дальнейшую детекцию.
#
# Работает рядом с transcribe_loop.fish отдельным процессом, читая его вывод --
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
        notify-send -u critical "К вам обратились" "$text"
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
            notify-send -u normal "Вопрос ко всем" "$text"
            echo "GROUP: $text"
            fish $STUDY_AGENT_DIR/draft_answer.fish "$text" "$ts" группа &
            disown
        else
            echo "GROUP (кулдаун, пропущено): $text"
        end
    end
end
