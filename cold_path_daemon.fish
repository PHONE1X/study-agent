#!/usr/bin/env fish
# Холодный путь: раз в интервал берёт то, что появилось в transcript.log с
# прошлого цикла, спрашивает у модели, сменилась ли тема, и пишет
# структурированные заметки в вольт Obsidian.
#
# --once прогоняет один цикл и выходит -- для тестов, та же логика, что у
# check_trigger.fish --test.

source (dirname (status --current-filename))/sa_config.fish
set -g OLLAMA_URL "http://127.0.0.1:11434/api/generate"
source (dirname (status --current-filename))/sa_common.fish
set -g MODEL (sa_model | string collect)
set -g TRANSCRIPT_FILE ~/.local/share/study-agent/transcript.log
set -g STATE_FILE ~/.local/share/study-agent/cold_path_state.json
set -g INTERVAL_FILE ~/.local/share/study-agent/interval
set -g VAULT_DIR $SA_VAULT_DIR
set -g STUDY_DIR $SA_STUDY_DIR
set -g SA_DIR_SELF (dirname (status --current-filename))
set -g GROUND_BULLETS $SA_DIR_SELF/ground_bullets.py

# Конспект.md раньше собирался только на agent stop. Для восьмичасовой лекции
# это ровно наоборот тому, что нужно: связный текст появлялся тогда, когда
# лекция уже кончилась. Теперь он пересобирается и по ходу сессии -- раз в
# SUMMARY_EVERY циклов, в фоне, чтобы цикл заметок его не ждал.
set -g SUMMARY_EVERY 3
set -g SUMMARY_LOCK ~/.local/share/study-agent/summary.lock
set -g CYCLE_COUNT 0

# Обычный цикл ~50 строк (5 мин при чанках по ~6с). 150 -- запас x3, но не весь
# бэклог разом: живьём проверено, что суммаризация ~700 строк в один промпт
# молча ловит таймаут и остаётся без конспекта. Если демон долго не работал --
# наверстывает по частям, за несколько циклов, а не за один большой прыжок.
set -g MAX_LINES_PER_CYCLE 150

# Сколько текста нужно накопить, прежде чем заводить новую сессию. Название
# курса модель придумывает по первому же фрагменту, и по двум словам («так,
# сейчас начнём») получается мусорное имя папки, которое потом живёт вечно.
#
# Считаем СИМВОЛЫ, а не строки. Раньше стояло «10 строк», и это молча сломалось,
# когда окно транскрипции выросло с 6 до 15 секунд: строк стало вдвое меньше,
# но каждая длиннее, и ожидание десяти строк растянулось до двух минут. Порог в
# символах от длины окна не зависит вообще -- 350 символов набирается примерно
# за полминуты речи и уже вполне описывает тему.
set -g MIN_CHARS_FOR_SESSION 350
set -g MIN_LINES_FOR_SESSION 2

function cold_interval --description "Интервал в секундах; читается каждый цикл, поэтому перезапуск не нужен"
    if test -f $INTERVAL_FILE
        set -l v (cat $INTERVAL_FILE | string trim | string collect)
        if string match -qr '^\d+$' -- "$v"
            echo $v
            return 0
        end
    end
    if set -q COLD_PATH_INTERVAL
        echo $COLD_PATH_INTERVAL
        return 0
    end
    echo 120
end

function sanitize_filename --argument-names name
    set -l clean (string trim -- (string replace -ra '[/\\\\:*?"<>|]' '' -- $name))
    # Длинные названия от модели ломают и файловую систему, и читаемость.
    string sub -l 60 -- $clean | string trim
end

function slugify --argument-names name
    string lower -- (string replace -ra '[^0-9A-Za-zА-Яа-яЁё-]+' '-' -- $name) \
        | string trim -c '-' | string sub -l 40
end

function ollama_generate --argument-names prompt
    set -l payload (jq -nc --arg model $MODEL --arg prompt "$prompt" \
        '{model: $model, prompt: $prompt, think: false, stream: false}')
    curl -s -m 120 -X POST $OLLAMA_URL -H "Content-Type: application/json" -d "$payload" \
        | jq -r '.response // empty'
end

function ollama_generate_json --argument-names prompt
    set -l payload (jq -nc --arg model $MODEL --arg prompt "$prompt" \
        '{model: $model, prompt: $prompt, think: false, stream: false, format: "json"}')
    curl -s -m 120 -X POST $OLLAMA_URL -H "Content-Type: application/json" -d "$payload" \
        | jq -r '.response // empty'
end

function plausible_title --argument-names text --description "Грубая проверка, что ответ похож на короткое название (3-6 слов), а не на разговорный ответ модели"
    set -l t (string trim -- $text)
    if test -z "$t"
        return 1
    end
    set -l wc (count (string split -n ' ' -- $t))
    if test $wc -gt 8
        return 1
    end
    if string match -qr '\?' -- $t
        return 1
    end
    return 0
end

function bullets_only --argument-names text --description "Оставляет только строки вида «- ...»; остальное -- не пункт конспекта"
    for l in (string split \n -- $text)
        if string match -qr '^-\s' -- $l
            echo $l
        end
    end
end

function first_time_of --argument-names text
    # Строки транскрипта имеют вид "[20:37:11] текст". Достаём HH:MM.
    set -l m (echo "$text" | head -n1 | string match -r '^\[(\d{2}:\d{2})')
    if test (count $m) -ge 2
        echo $m[2]
    end
end

function last_time_of --argument-names text
    set -l m (echo "$text" | tail -n1 | string match -r '^\[(\d{2}:\d{2})')
    if test (count $m) -ge 2
        echo $m[2]
    end
end

function cold_path_cycle
    if not test -f $TRANSCRIPT_FILE
        echo "COLD PATH: no transcript file yet, skipping cycle."
        return
    end

    set -l total_lines (wc -l < $TRANSCRIPT_FILE | string trim)
    set -l last_line 0
    if test -f $STATE_FILE
        set last_line (jq -r '.last_line // 0' $STATE_FILE)
    end

    if test "$total_lines" -le "$last_line"
        echo "COLD PATH: nothing new since line $last_line, skipping cycle."
        return
    end

    set -l start_line (math $last_line + 1)
    set -l end_line $total_lines
    if test (math $end_line - $start_line + 1) -gt $MAX_LINES_PER_CYCLE
        set end_line (math $start_line + $MAX_LINES_PER_CYCLE - 1)
        echo "COLD PATH: backlog capped -- processing $start_line..$end_line this cycle, rest next cycle(s)."
    end
    # string collect обязателен: без него fish разрежет вывод по строкам в
    # список, и текст склеится пробелами при обратной подстановке.
    set -l new_lines (sed -n "$start_line,$end_line p" $TRANSCRIPT_FILE | string collect)

    set -l t_start (first_time_of "$new_lines" | string collect)
    set -l t_end (last_time_of "$new_lines" | string collect)
    set -l t_range "$t_start"
    if test -n "$t_end" -a "$t_end" != "$t_start"
        set t_range "$t_start — $t_end"
    end

    mkdir -p $STUDY_DIR

    set -l existing_session_dir ""
    if test -f $STATE_FILE
        set existing_session_dir (jq -r '.session_dir // empty' $STATE_FILE)
    end

    # Папка сессии могла исчезнуть: её удалили вручную, перенесли или почистили
    # вольт. Раньше это ломало демон молча -- session_dir в state оставался
    # заполненным, ветка создания новой сессии пропускалась, и каждая запись
    # уходила по несуществующему пути. При этом last_line продолжал расти,
    # поэтому материал считался обработанным и пропадал навсегда.
    # Теперь пропавшая папка -- это сигнал начать новую сессию с нуля.
    if test -n "$existing_session_dir"; and not test -d "$STUDY_DIR/$existing_session_dir"
        echo "COLD PATH: папка сессии «$existing_session_dir» исчезла -- начинаю новую сессию."
        set existing_session_dir ""
    end

    if test -z "$existing_session_dir"
        # Не заводим сессию по обрывку: имя папки берётся из первого фрагмента
        # и уже не меняется, поэтому лучше подождать ещё цикл, чем получить
        # «2026-08-20 Так сейчас начнём» на весь курс.
        set -l got_lines (math $end_line - $start_line + 1)
        set -l got_chars (string length -- "$new_lines")
        if test $got_lines -lt $MIN_LINES_FOR_SESSION -o $got_chars -lt $MIN_CHARS_FOR_SESSION
            echo "COLD PATH: пока мало материала для названия сессии ($got_chars из $MIN_CHARS_FOR_SESSION символов, строк $got_lines) -- жду следующий цикл."
            return
        end

        # Первый цикл этой сессии (или после reset_session.fish). Проверяем
        # session_dir, а не наличие файла: reset оставляет "заряженный" state с
        # одним last_line, чтобы пропустить старый бэклог, но без session_dir --
        # это тоже должно бутстрапить новую сессию.
        set -l title_prompt "Вот начало учебной сессии (транскрипт на русском):

$new_lines

Дай короткое название теме курса (3-6 слов, без кавычек, без точки в конце) — то, о чём эта сессия в целом. Ответь только названием, без пояснений."
        set -l raw_title (ollama_generate $title_prompt | string trim | string collect)
        if not plausible_title "$raw_title"
            echo "COLD PATH: модель не дала короткое название курса (ответ не похож на название) -- использую заглушку" >&2
            set raw_title ""
        end
        set -l course_title (sanitize_filename "$raw_title")
        if test -z "$course_title"
            set course_title "Без названия"
        end

        set -l date_str (date "+%Y-%m-%d")
        set -l session_dir "$date_str $course_title"
        mkdir -p "$STUDY_DIR/$session_dir"

        echo "# $course_title

Дата: $date_str
Теги: #обучение/"(slugify "$course_title" | string collect)"

## Сегменты
" > "$STUDY_DIR/$session_dir/Обзор.md"

        if not test -f "$STUDY_DIR/$SA_STUDY_SUBDIR.md"
            echo "# Обучение — индекс сессий
" > "$STUDY_DIR/$SA_STUDY_SUBDIR.md"
        end
        echo "- [[$session_dir/Обзор|$course_title ($date_str)]]" >> "$STUDY_DIR/$SA_STUDY_SUBDIR.md"

        # segment_title намеренно пустой: сегмент 1 должен получить СВОЮ тему,
        # а не продублировать название курса. Раньше здесь стоял course_title,
        # из-за чего папка, файл сегмента и тег назывались одинаково.
        # session_start_line -- с какой строки transcript.log началась эта
        # сессия. Нужен зеркалу транскрипта (transcript_mirror.fish): оно
        # стартует позже, чем появилась папка, и должно долить всё с начала
        # сессии, а не только то, что пришло после его запуска.
        jq -n --arg dir "$session_dir" --arg course "$course_title" --argjson sstart $start_line \
            '{session_dir: $dir, course_title: $course, segment_num: 0, segment_title: "", segment_file: "", last_line: 0, session_start_line: $sstart}' \
            > $STATE_FILE

        echo "COLD PATH: new session started -- $session_dir"
    end

    set -l session_dir (jq -r '.session_dir' $STATE_FILE)
    set -l course_title (jq -r '.course_title // ""' $STATE_FILE)
    set -l segment_num (jq -r '.segment_num' $STATE_FILE)
    set -l segment_title (jq -r '.segment_title' $STATE_FILE)
    set -l segment_file (jq -r '.segment_file' $STATE_FILE)
    set -l session_start_line (jq -r '.session_start_line // 0' $STATE_FILE)

    set -l session_path "$STUDY_DIR/$session_dir"

    # Вторая страховка: папку могли удалить между проверкой выше и записью,
    # либо Обзор.md пропал отдельно от папки. Без mkdir перенаправление ">>"
    # молча падает, и цикл заканчивается ничем.
    mkdir -p "$session_path"
    if not test -f "$session_path/Обзор.md"
        echo "# $course_title

Дата: "(date "+%Y-%m-%d")"
Теги: #обучение/"(slugify "$course_title" | string collect)"

## Сегменты
" > "$session_path/Обзор.md"
    end

    # Транскрипт сюда больше не пишется. Раньше он появлялся в вольте раз в
    # цикл, то есть рывками по 5 минут, и до первого цикла папка выглядела
    # мёртвой -- «агент ничего не делает». Теперь Транскрипт.md ведёт
    # transcript_mirror.fish: он доливает строки раз в пару секунд, поэтому
    # заметка растёт на глазах, независимо от того, сколько думает модель.
    # Держать здесь вторую запись нельзя -- строки задвоятся.

    set -l new_segment false
    if test "$segment_num" -eq 0
        set new_segment true
        set -l seg_prompt "Вот фрагмент транскрипта учебной сессии:

$new_lines

Дай короткое название именно ЭТОМУ фрагменту (3-6 слов, без кавычек, без точки в конце) — о чём говорят прямо здесь. Не описывай курс целиком. Ответь только названием."
        set -l raw (ollama_generate $seg_prompt | string trim | string collect)
        if not plausible_title "$raw"
            echo "COLD PATH: модель не дала короткое название сегмента -- использую заглушку" >&2
            set raw ""
        end
        set segment_title (sanitize_filename "$raw")
        if test -z "$segment_title"
            set segment_title "Начало"
        end
    else
        set -l decide_prompt "Текущий сегмент заметок называется «$segment_title». Вот новый фрагмент транскрипта:

$new_lines

Сменилась ли тема настолько, что нужен новый сегмент заметок?

Новый сегмент нужен, если:
- пошла действительно другая тема;
- сменился докладчик или начался новый доклад («передаю слово», «следующий доклад», «спасибо, а теперь»).

Новый сегмент НЕ нужен при новом примере, отступлении, шутке, вопросе из зала или продолжении той же мысли.

Рекламная вставка (промокод, скидка, аукцион, «ссылка в описании», хостинг, спонсор) — ЭТО НЕ СМЕНА ТЕМЫ. Реклама вклинивается в середину занятия и заканчивается, после чего докладчик возвращается к прежней теме. Никогда не заводи сегмент под рекламу и не называй сегмент по рекламодателю. Ответь только JSON вида {\"new_segment\": true, \"title\": \"короткое название новой темы\"} или {\"new_segment\": false, \"title\": \"\"}."
        set -l decision (ollama_generate_json $decide_prompt | string collect)
        set -l is_new (echo "$decision" | jq -r '.new_segment // false' 2>/dev/null)
        if test "$is_new" = "true"
            set new_segment true
            set -l raw (echo "$decision" | jq -r '.title // empty' 2>/dev/null | string collect)
            if not plausible_title "$raw"
                echo "COLD PATH: модель не дала короткое название нового сегмента -- использую заглушку" >&2
                set raw ""
            end
            set -l new_title (sanitize_filename "$raw")
            if test -n "$new_title"
                set segment_title $new_title
            else
                set segment_title "Новый сегмент"
            end
        end
    end

    if test "$new_segment" = "true"
        set segment_num (math $segment_num + 1)
        set -l num_padded (printf "%02d" $segment_num)
        set segment_file "$num_padded $segment_title.md"
        set -l course_tag (slugify "$course_title" | string collect)
        # Заголовок сегмента: тема пишется один раз как H1, тег -- курсовой и
        # общий для всех сегментов сессии. Раньше название дублировалось трижды
        # (папка, файл, тег), и по заметке было непонятно, что где.
        echo "# $segment_title

**Сессия:** [[Обзор|$course_title]] · **Начало:** $t_start
**Теги:** #обучение/$course_tag
" > "$session_path/$segment_file"
        set -l link_name (string replace -r '\\.md$' '' -- $segment_file)
        echo "- [[$link_name|$segment_title]] — $t_start" >> "$session_path/Обзор.md"
        echo "COLD PATH: new segment $num_padded -- $segment_title"
    end

    # Хвост предыдущего фрагмента. Без него местоимения повисают в воздухе:
    # название предмета произносится в одном окне, а «этот амулет» -- уже в
    # следующем, и модель физически не может подставить название, потому что
    # его нет во входных данных. Ровно отсюда брались пункты вида «Амулет
    # повышает мощь» без единого намёка, о каком амулете речь.
    set -l prev_context ""
    if test $start_line -gt 1
        set -l ctx_from (math "max(1, $start_line - 8)")
        set prev_context (sed -n "$ctx_from,"(math $start_line - 1)" p" $TRANSCRIPT_FILE | string collect)
    end

    # ВАЖНО про примеры в инструкции. Раньше здесь стоял образец формулировки
    # с настоящим числом, и модель скопировала его в заметки как факт: на
    # стриме по Elden Ring дважды появился пункт «Объём корпуса — 3.8 литра»,
    # которого не было ни в одном окне транскрипта. Поэтому в требованиях
    # больше нет ни чисел, ни названий, ни готовых формулировок -- только
    # описание того, что делать. Всё, что здесь написано буквально, модель
    # рано или поздно перепишет в конспект.
    set -l summarize_prompt "Тема сессии: «$course_title». Текущий раздел: «$segment_title».

Законспектируй по-русски фрагмент транскрипта, приведённый ниже.

Требования к ответу:
- только маркированный список, каждый пункт с новой строки, начинается с «- »;
- одна мысль на пункт, без вступлений и без выводов в конце;
- не повторяй одно и то же разными словами;
- пиши ТОЛЬКО то, что прямо сказано во фрагменте. Ничего не добавляй от себя,
  не обобщай и не переворачивай смысл: если сказано, что что-то ослабили, не
  пиши, что усилили; если названы две вещи по отдельности, не связывай их
  причиной и следствием, которой в тексте нет;
- это может быть живая конференция: пропускай шутки, приветствия, болтовню,
  организационные объявления и обсуждение регламента — в конспект идёт только
  содержание;
- ПРОПУСКАЙ РЕКЛАМУ ЦЕЛИКОМ. Признаки рекламной вставки: промокод, скидка,
  «переходите по ссылке в описании», «сканируйте QR-код», аукцион, тариф,
  название хостинга, магазина или сервиса в хвалебном контексте, обещание
  бесплатного продукта. Про рекламу не пишется НИ ОДНОГО пункта — даже
  «докладчик рассказал о спонсоре». Реклама не имеет отношения к теме занятия;
- то же касается самого канала: просьбы поставить лайк, подписаться,
  поддержать, ссылки в описании, обсуждение чата и его команд — не содержание;
- отдельно: докладчик часто рекламирует СВОЁ. Запуск платформы, набор на
  курс, программы обучения, бесплатные и платные тарифы, буткемпы, вебинары,
  сообщество, телеграм-канал, «мы это исправим на нашем курсе» — всё это
  реклама, даже если продукт бесплатный и относится к теме занятия. В конспект
  идёт только то, чему учат прямо сейчас, а не то, куда зовут записаться;
- не пиши пунктов-связок, из которых ничего не следует: «сегодня это
  исправим», «об этом поговорим дальше», «сейчас разберёмся». Это анонс, а
  не знание;
- если это прямой эфир, пропускай донаты и всё, что с ними связано: ники
  зрителей, обращения к ним по имени, суммы, благодарности за поддержку,
  реплики из чата и ответы на них. Числа, прозвучавшие в таком обмене, —
  тоже не содержание;
- каждый пункт должен быть понятен сам по себе, без транскрипта. Вместо
  местоимения подставляй название предмета: ищи его выше во фрагменте или в
  блоке «Ранее». Если названия нет нигде — пункт не пиши. Не начинай пункт с
  «это», «он», «она», «там». Число без предмета не пиши вообще;
- сохраняй числа и названия, которые есть во фрагменте: конкретика важнее
  общих формулировок. Если во фрагменте названа величина — она должна попасть
  в пункт, а не потеряться;
- пиши законченными фразами, из которых понятно, что происходит и зачем.
  Безличные огрызки в духе «предмет покупается», «ключ необходим», «оружие
  улучшается» бесполезны: из них нельзя ничего узнать. Если во фрагменте
  сказано, зачем это делают или что это даёт — это и есть содержание пункта,
  и без него пункт не нужен;
- не пиши о говорящем («автор показывает», «пользователь идёт») — пиши о
  предмете. Важно то, что он объясняет, а не то, что он в этот момент делает;
- не больше восьми пунктов на фрагмент. Лучше пять содержательных, чем
  пятнадцать обрывков. Если мысль одна — пункт тоже один;
- пропускай то, из чего ничего нельзя узнать: что кому-то что-то показали,
  сфотографировали, что видно на экране, что выглядит красиво;
- транскрипт получен распознаванием речи и содержит ошибки в словах, числах и
  названиях. Если ты не можешь понять, что означает конкретное слово, —
  не переписывай это слово в конспект и не строй вокруг него пункт: пропусти
  такой пункт целиком. Если не уверен в названии или числе, поставь после
  него (?);
- если во фрагменте нет содержательной информации, ответь одной строкой: НЕТ.

Ранее в этом же разделе (нужно только чтобы понимать, о чём идёт речь;
конспектировать этот блок НЕ надо):

$prev_context

Фрагмент для конспекта:

$new_lines"
    # string collect обязателен и здесь. Без него многострочный ответ модели
    # превращался в список, а echo склеивал его пробелами -- именно поэтому
    # маркированный список выглядел как одна сплошная строка.
    set -l summary (ollama_generate $summarize_prompt | string trim | string collect)

    # Гвард формата: модель иногда игнорирует «только список» и отвечает
    # обычным текстом (типичный симптом -- фразы вида «похоже, вы прислали
    # текст из чата»). Такой ответ в заметки не идёт: он не пункт конспекта,
    # а разговор с моделью. Оставляем только строки, реально начинающиеся с
    # «- »; если таких нет вовсе -- одна попытка переспросить построже.
    if test -n "$summary" -a "$summary" != "НЕТ"
        set -l bullets (bullets_only $summary | string collect)
        if test -z (string trim -- "$bullets" | string collect)
            echo "COLD PATH: ответ модели не в формате списка ($t_range), переспрашиваю" >&2
            set summary (ollama_generate "$summarize_prompt

Важно: в прошлый раз ты ответил не списком, а обычным текстом. Ответь СТРОГО списком: каждая строка начинается с «- », без вступлений, без заключений, без комментариев о самом ответе." | string trim | string collect)
            set bullets (bullets_only $summary | string collect)
        end
        # Последний рубеж перед вольтом: пункт, слов которого во фрагменте нет,
        # в заметки не попадает. Промпт просить можно сколько угодно, но модель
        # уже доказала, что способна выдать за факт строку из самой инструкции,
        # поэтому проверка здесь детерминированная, а не ещё одна просьба.
        # Сверяем и с блоком «Ранее» тоже. Иначе проверка вступает в прямой
        # конфликт с инструкцией: модели велено подставлять название предмета
        # из предыдущих строк -- и ровно такой, правильно названный пункт
        # выбрасывался как «слов нет во фрагменте». Источником считается всё,
        # что модель видела, а не только окно этого цикла.
        set -l frag_file (mktemp -t study-agent-frag.XXXXXX)
        printf '%s\n' $prev_context $new_lines > $frag_file
        set bullets (printf '%s\n' $bullets | python3 $GROUND_BULLETS $frag_file | string collect)
        rm -f $frag_file

        if test -n (string trim -- "$bullets" | string collect)
            echo "
### $t_range

$bullets" >> "$session_path/$segment_file"
        else if test "$summary" != "НЕТ"
            echo "COLD PATH: ответ модели так и не стал списком ($t_range) — фрагмент пропущен, чтобы не засорять конспект" >&2
        end
    end

    # Проверяем результат, а не факт запуска: если запись не удалась, цикл
    # обязан сказать об этом вслух, а не оставить пустую папку и довольный лог.
    if not test -s "$session_path/$segment_file"
        echo "COLD PATH: ОШИБКА -- файл «$segment_file» не создан в $session_path. Заметки никуда не пишутся." >&2
    end

    jq -n --arg dir "$session_dir" --arg course "$course_title" --argjson num $segment_num \
        --arg title "$segment_title" --arg file "$segment_file" --argjson last $end_line \
        --argjson sstart $session_start_line \
        '{session_dir: $dir, course_title: $course, segment_num: $num, segment_title: $title, segment_file: $file, last_line: $last, session_start_line: $sstart}' \
        > $STATE_FILE

    echo "COLD PATH: cycle done -- segment $segment_num ($segment_title), lines $start_line -> $end_line"

    set CYCLE_COUNT (math $CYCLE_COUNT + 1)
    if test (math "$CYCLE_COUNT % $SUMMARY_EVERY") -eq 0
        # Замок снимает сама фоновая сборка. Если она умерла, не сняв его,
        # висящий файл заблокировал бы конспект навсегда -- поэтому старый
        # замок считается протухшим и игнорируется.
        if test -f $SUMMARY_LOCK; and test (path mtime $SUMMARY_LOCK) -gt (math (date +%s) - 900)
            echo "COLD PATH: прошлая сборка конспекта ещё идёт -- пропускаю этот раз"
        else
            echo "COLD PATH: пересобираю Конспект.md в фоне (сессия продолжается)"
            fish -c "touch $SUMMARY_LOCK; $SA_DIR_SELF/make_summary.fish >/dev/null 2>&1; rm -f $SUMMARY_LOCK" &
            disown
        end
    end
end

if test "$argv[1]" = "--once"
    cold_path_cycle
    exit 0
end

function session_open --description "Есть ли уже заведённая папка сессии"
    test -f $STATE_FILE; or return 1
    set -l d (jq -r '.session_dir // empty' $STATE_FILE | string collect)
    test -n "$d"
end

cold_path_cycle   # первый цикл сразу, не ждём до появления заметок
while true
    # Пока сессии нет, опрашиваем часто: папка в вольте должна появиться через
    # минуту после старта, а не через полный интервал. Ждать целый интервал
    # ради первой папки -- это ровно то, из-за чего казалось, что агент не
    # работает вовсе. Как только сессия заведена, переходим на обычный ритм.
    if session_open
        sleep (cold_interval)
    else
        sleep 8
    end
    cold_path_cycle
end
