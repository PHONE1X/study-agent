#!/usr/bin/env fish
# Собирает итоговый конспект сессии — файл «Конспект.md» в папке сессии.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ШАГ.
#
# Холодный путь пишет заметки инкрементально: раз в несколько минут берёт
# свежий кусок транскрипта и выжимает из него пункты. Это полезно как черновик,
# но прочесть такое подряд нельзя: каждый кусок суммаризован в отрыве от
# соседних, поэтому связки между мыслями теряются, а повторы наоборот копятся.
#
# Метод, по которому это собирается, сложен из двух общепризнанных практик.
#
# 1. Послойное сжатие (Progressive Summarization, Tiago Forte). Материал
#    проходит несколько слоёв, каждый следующий короче предыдущего, но
#    предыдущий никуда не девается и остаётся доступен:
#       слой 0  Транскрипт.md      — сырая расшифровка
#       слой 1  сегменты 01, 02…   — пункты по ходу дела
#       слой 2  Конспект.md        — связный текст, ради которого всё
#    Ключевая идея метода: сжатие всегда стоит потери контекста, поэтому
#    нижние слои не выбрасываются, а остаются рядом.
#
# 2. Структура Корнелла (Cornell Notes). Классический учебный конспект состоит
#    не только из самих заметок: сверху краткое резюме, сбоку колонка
#    вопросов-подсказок для самопроверки. Именно резюме и вопросы превращают
#    набор фактов в то, по чему можно готовиться, а не просто перечитывать.
#
# Поэтому Конспект.md собирается так:
#       Кратко              — 3-5 предложений, суть целиком
#       Главное             — связное повествование
#       Ключевые тезисы     — то же по пунктам, для быстрого просмотра
#       Вопросы             — колонка подсказок Корнелла, для самопроверки
#       Термины и числа     — конкретика, которую легко забыть
#       Сомнительные места  — где распознавание речи могло наврать

source (dirname (status --current-filename))/sa_config.fish
set -g SA_DIR (dirname (status --current-filename))
set -g OLLAMA_URL "http://127.0.0.1:11434/api/generate"
source $SA_DIR/sa_common.fish
# Модель можно переопределить аргументом --model, чтобы сравнить две модели
# на одном и том же материале: agent summary --model gemma3:12b
set -g MODEL (sa_model | string collect)
if set -l i (contains -i -- --model $argv)
    set -l next (math $i + 1)
    if test $next -le (count $argv)
        set MODEL $argv[$next]
    end
end
set -g STATE_FILE ~/.local/share/study-agent/cold_path_state.json
set -g ASKS_FILE ~/.local/share/study-agent/asks.jsonl
set -g VAULT_DIR $SA_VAULT_DIR
set -g STUDY_DIR $SA_STUDY_DIR

# Потолок на один промпт. Видеокарта подрезана по частоте, а обработка промпта
# упирается именно в вычисления, поэтому длинный материал сначала сжимается
# группами, и только потом собирается целиком.
set -g MAX_CHUNK_CHARS 5000

function ollama_ask --argument-names prompt timeout_s
    if test -z "$timeout_s"
        set timeout_s 180
    end
    set -l payload (jq -nc --arg model $MODEL --arg prompt "$prompt" \
        '{model: $model, prompt: $prompt, think: false, stream: false}')
    curl -s -m $timeout_s -X POST $OLLAMA_URL -H "Content-Type: application/json" -d "$payload" \
        | jq -r '.response // empty' | string trim | string collect
end

function ollama_ask_json --argument-names prompt timeout_s
    if test -z "$timeout_s"
        set timeout_s 180
    end
    set -l payload (jq -nc --arg model $MODEL --arg prompt "$prompt" \
        '{model: $model, prompt: $prompt, think: false, stream: false, format: "json"}')
    curl -s -m $timeout_s -X POST $OLLAMA_URL -H "Content-Type: application/json" -d "$payload" \
        | jq -r '.response // empty' | string trim | string collect
end

# --- сбор материала -------------------------------------------------------

if not test -f $STATE_FILE
    echo "Конспект: сессия ещё не начата, собирать нечего."
    exit 1
end

set -g session_dir (jq -r '.session_dir // empty' $STATE_FILE | string collect)
set -g course_title (jq -r '.course_title // ""' $STATE_FILE | string collect)

if test -z "$session_dir"
    echo "Конспект: сессия ещё не начата, собирать нечего."
    exit 1
end

set -g SESSION_PATH "$STUDY_DIR/$session_dir"
if not test -d "$SESSION_PATH"
    echo "Конспект: папка сессии не найдена: $SESSION_PATH"
    exit 1
end

if test -z "$course_title"
    set course_title $session_dir
end

# Материал — пункты из файлов сегментов. Заголовок сегмента идёт как контекст,
# чтобы модель видела, к какой теме относится каждая группа пунктов.
set -g material ""
set -g segment_count 0
# Внимание: в fish в глобах НЕТ диапазонов вида [0-9] -- поддерживаются только
# *, ** и ?. Поэтому имена сегментов отбираются регулярным выражением, а не
# глобом: глоб "[0-9][0-9]*.md" молча не находил ничего.
for name in (ls -1 "$SESSION_PATH" 2>/dev/null | string match -r '^[0-9][0-9] .*\.md$')
    set -l f "$SESSION_PATH/$name"
    if not test -f "$f"
        continue
    end
    set segment_count (math $segment_count + 1)
    set -l title (head -n1 "$f" | string replace -r '^#\s*' '' | string collect)
    set -l body (grep -E '^\s*[-*] ' "$f" | string collect)
    if test -n "$body"
        set material "$material

## $title
$body"
    end
end

# Если сегментов ещё нет или они пустые — берём сырой транскрипт как запасной
# источник, иначе конспект собирать не из чего.
if test -z (string trim -- "$material" | string collect)
    if test -f "$SESSION_PATH/Транскрипт.md"
        echo "Конспект: пунктов в сегментах нет, беру сырой транскрипт."
        set material (tail -n 400 "$SESSION_PATH/Транскрипт.md" | string collect)
    else
        echo "Конспект: материала нет."
        exit 1
    end
end

# --- предварительное сжатие длинного материала ----------------------------

function prereduce --argument-names text
    set -l len (string length -- "$text")
    if test "$len" -le "$MAX_CHUNK_CHARS"
        echo $text
        return 0
    end

    echo "Конспект: материала $len символов, сжимаю группами..." >&2
    set -l lines (printf '%s\n' $text | string split \n)
    set -l acc ""
    set -l out ""
    for l in $lines
        set acc "$acc
$l"
        if test (string length -- "$acc") -ge $MAX_CHUNK_CHARS
            set -l p "Сожми эти рабочие заметки, сохранив всю фактическую конкретику (числа, названия, выводы) и выбросив повторы и общие слова. Ответь маркированным списком, по одному пункту на мысль.

$acc"
            set -l r (ollama_ask $p 180)
            set out "$out
$r"
            set acc ""
        end
    end
    if test -n (string trim -- "$acc" | string collect)
        set -l p "Сожми эти рабочие заметки, сохранив всю фактическую конкретику (числа, названия, выводы) и выбросив повторы и общие слова. Ответь маркированным списком, по одному пункту на мысль.

$acc"
        set -l r (ollama_ask $p 180)
        set out "$out
$r"
    end
    echo $out
end

set -g material (prereduce "$material" | string collect)

# --- слой 2: связное повествование ----------------------------------------

echo "Конспект: пишу связный текст..."

set -g narrative_prompt "Ты составляешь учебный конспект по теме «$course_title».

Вот рабочие заметки, собранные по ходу материала:
$material

Напиши раздел «Главное» — связный текст, который человек прочтёт ВМЕСТО просмотра исходного видео и после этого будет понимать, о чём шла речь.

Требования:
- это повествование абзацами, а не список пунктов;
- сохрани логику изложения: от чего к чему шёл рассказ и какие выводы получились;
- конкретика важнее общих слов: числа, названия, сравнения, итоги;
- выбрось повторы, отступления, рекламные вставки и всё, что не несёт информации;
- будь примерно в три-пять раз короче исходных заметок, но не теряй сути;
- пиши по-русски, живым простым языком, без канцелярита и без вводных фраз;
- ничего не добавляй от себя: если чего-то нет в заметках, этого нет и в конспекте.

Ответь только текстом раздела, без заголовка и без пояснений."

set -g narrative (ollama_ask $narrative_prompt 300)

if test -z "$narrative"
    echo "Конспект: модель не ответила на основной запрос. Попробуй ещё раз: agent summary" >&2
    exit 1
end

# --- слой 2: структурная обвязка по Корнеллу ------------------------------

echo "Конспект: собираю резюме, тезисы и вопросы..."

set -g extras_prompt "Вот конспект по теме «$course_title»:

$narrative

Верни JSON строго такого вида, по-русски:
{
  \"tldr\": \"3-5 предложений: о чём это целиком и что главное\",
  \"theses\": [\"ключевой тезис\", \"...\"],
  \"questions\": [\"вопрос для самопроверки по материалу\", \"...\"],
  \"terms\": [{\"term\": \"термин или число\", \"what\": \"что это значит\"}],
  \"unclear\": [\"место, где формулировка выглядит сомнительно или оборванно\"]
}

Правила: тезисов 5-10, вопросов 4-8 — они должны проверять понимание, а не память на слова. В terms клади только то, что реально встречалось. В unclear клади только то, что действительно выглядит как ошибка распознавания речи; если такого нет, оставь пустой список."

set -g extras (ollama_ask_json $extras_prompt 240)

function jq_list --argument-names json path
    echo "$json" | jq -r --arg p "$path" '.[$p] // [] | .[]? | select(type=="string")' 2>/dev/null
end

set -g tldr (echo "$extras" | jq -r '.tldr // empty' 2>/dev/null | string collect)

# --- сборка файла ---------------------------------------------------------

set -g date_str (date "+%Y-%m-%d")
set -g out "$SESSION_PATH/Конспект.md"

begin
    echo "---"
    echo "tags:"
    echo "  - обучение/конспект"
    echo "дата: $date_str"
    echo "сессия: \"[[Обзор]]\""
    echo "---"
    echo ""
    echo "# $course_title — конспект"
    echo ""
    if test -n "$tldr"
        echo "> [!abstract] Кратко"
        printf '%s\n' (string split \n -- "$tldr" | string replace -r '^' '> ')
        echo ""
    end
    echo "## Главное"
    echo ""
    echo "$narrative"
    echo ""

    set -l th (jq_list "$extras" theses)
    if test (count $th) -gt 0
        echo "## Ключевые тезисы"
        echo ""
        for t in $th
            echo "- $t"
        end
        echo ""
    end

    set -l qs (jq_list "$extras" questions)
    if test (count $qs) -gt 0
        echo "## Вопросы для самопроверки"
        echo ""
        for q in $qs
            echo "- [ ] $q"
        end
        echo ""
    end

    set -l terms (echo "$extras" | jq -r '.terms // [] | .[]? | select(.term != null) | "| \(.term) | \(.what // "") |"' 2>/dev/null)
    if test (count $terms) -gt 0
        echo "## Термины и числа"
        echo ""
        echo "| Что | Значение |"
        echo "| :--- | :--- |"
        for t in $terms
            echo $t
        end
        echo ""
    end

    set -l un (jq_list "$extras" unclear)
    if test (count $un) -gt 0
        echo "## Сомнительные места"
        echo ""
        echo "Здесь распознавание речи могло ошибиться — если тема важная, свериться стоит по транскрипту."
        echo ""
        for u in $un
            echo "- $u"
        end
        echo ""
    end

    # Отсылки к визуальному материалу. Ищутся регулярным выражением по сырому
    # транскрипту, без модели: это дёшево, детерминированно и не врёт. Смысл
    # раздела в том, что агент слышит только звук. Когда докладчик говорит «вот
    # на этом слайде», информация физически отсутствует в транскрипте, и никакая
    # суммаризация её не восстановит. Значит, нужно хотя бы точно указать
    # моменты, которые придётся досмотреть глазами.
    if test -f "$SESSION_PATH/Транскрипт.md"
        set -l visual (grep -inE '(слайд|на экране|на схеме|на графике|на диаграмме|на картинке|на рисунке|в таблице|покажу|показываю|демонстрир|посмотрите на|обратите внимание на)' "$SESSION_PATH/Транскрипт.md" 2>/dev/null | sed 's/^[0-9]*://' | head -n 40)
        if test (count $visual) -gt 0
            echo "## Смотреть в записи"
            echo ""
            echo "Здесь докладчик ссылался на то, что видно на экране. В звуке этой информации нет, поэтому эти моменты стоит досмотреть глазами."
            echo ""
            for v in $visual
                set -l vt (string match -r '^\[(\d{2}:\d{2})' -- $v)
                set -l vtext (string replace -r '^\[\d+:\d+:\d+\]\s*' '' -- $v)
                if test (count $vt) -ge 2
                    echo "- **$vt[2]** — $vtext"
                else
                    echo "- $vtext"
                end
            end
            echo ""
        end
    end

    # Обращения лично к тебе -- отдельным разделом, потому что это единственная
    # часть сессии, которая требовала реакции здесь и сейчас.
    if test -f "$ASKS_FILE"
        set -l mine (jq -r --arg s "$session_dir" 'select(.session == $s and .type != "упоминание") | "- **\(.ts)** \(.question)" + (if (.answer // "") == "" then "" else "\n  - _черновик:_ \(.answer)" end)' $ASKS_FILE 2>/dev/null)
        if test (count $mine) -gt 0
            echo "## Обращения к тебе"
            echo ""
            for m in $mine
                echo $m
            end
            echo ""
            echo "Полный журнал: [[Обращения]]"
            echo ""
        end
    end

    echo "---"
    echo ""
    echo "Слои материала: [[Транскрипт|сырая расшифровка]] → сегменты ($segment_count шт., см. [[Обзор]]) → этот конспект."
end > "$out"

# Ссылка на конспект первой строкой в Обзоре, если её ещё нет.
set -g overview "$SESSION_PATH/Обзор.md"
if test -f "$overview"
    if not grep -q '\[\[Конспект\]\]' "$overview"
        set -l tmp "$overview.tmp"
        begin
            head -n1 "$overview"
            echo ""
            echo "**[[Конспект]]** — связный конспект всей сессии, начинать читать отсюда."
            tail -n +2 "$overview"
        end > $tmp; and mv $tmp "$overview"
    end
end

echo "Конспект готов: $out"
