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
    end
end
