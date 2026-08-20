#!/usr/bin/env fish
# Общие настройки, которые нужны нескольким скриптам сразу.
# Только определения функций, ничего не выполняет.

set -g SA_DATA_DIR ~/.local/share/study-agent
set -g SA_MODEL_FILE $SA_DATA_DIR/model
set -g SA_DEFAULT_MODEL qwen3:8b

# Размер контекста модели. По умолчанию Ollama даёт 4096 токенов, и этого не
# хватает: под генерацию резервируется место, реально на вход остаётся около
# 2000 токенов. Всё, что длиннее, Ollama молча обрезает -- конспект собирался
# по огрызку материала и потому не менялся по ходу занятия.
#
# ВАЖНО: значение должно быть одинаковым во ВСЕХ запросах, включая прогрев.
# При смене num_ctx Ollama перезагружает модель (~7 секунд), поэтому разные
# значения у разных вызовов означали бы перезагрузку на каждом переключении.
set -g SA_NUM_CTX 32768

function sa_model --description "Имя модели Ollama для всех запросов агента"
    if test -f $SA_MODEL_FILE
        set -l m (cat $SA_MODEL_FILE 2>/dev/null | string trim | string collect)
        if test -n "$m"
            echo $m
            return 0
        end
    end
    echo $SA_DEFAULT_MODEL
end

function sa_model_set --argument-names name
    test -n "$name"; or return 1
    mkdir -p $SA_DATA_DIR
    echo $name > $SA_MODEL_FILE
end

function sa_model_loaded --description "Печатает имена моделей, которые сейчас держатся в памяти"
    curl -s -m 3 http://127.0.0.1:11434/api/ps 2>/dev/null \
        | jq -r '.models // [] | .[] | .name' 2>/dev/null
end

function sa_model_unload --description "Выгружает модель агента из видеопамяти"
    set -l m (sa_model | string collect)
    # keep_alive: 0 говорит Ollama выгрузить модель сразу после запроса.
    # Это перебивает глобальный OLLAMA_KEEP_ALIVE=-1, который держит её
    # резидентной, чтобы горячий путь не ждал загрузку на каждый вопрос.
    curl -s -m 15 -X POST http://127.0.0.1:11434/api/generate \
        -H "Content-Type: application/json" \
        -d (jq -nc --arg m "$m" '{model: $m, prompt: "", keep_alive: 0}') >/dev/null 2>&1
    or command -q ollama; and ollama stop $m >/dev/null 2>&1
end

function sa_model_warm --description "Заранее поднимает модель в видеопамять"
    set -l m (sa_model | string collect)
    curl -s -m 120 -X POST http://127.0.0.1:11434/api/generate \
        -H "Content-Type: application/json" \
        -d (jq -nc --arg m "$m" --argjson ctx $SA_NUM_CTX '{model: $m, prompt: "ок", think: false, stream: false, keep_alive: -1, options: {num_ctx: $ctx}}') >/dev/null 2>&1
end
