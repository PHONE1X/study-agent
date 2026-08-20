#!/usr/bin/env fish
# Настройки, которые зависят от машины и от человека.
#
# Значения по умолчанию заданы прямо здесь. Переопределить их можно в файле
# ~/.config/study-agent/config.env -- он в формате KEY=значение, потому что
# читать его должны и fish-скрипты, и python-скрипты. Образец лежит рядом:
# config.example.env.
#
# Ничего не выполняет само по себе, кроме чтения настроек.

set -q SA_VAULT_DIR; or set -g SA_VAULT_DIR ~/Documents/Obsidian
set -q SA_STUDY_SUBDIR; or set -g SA_STUDY_SUBDIR Обучение
set -q SA_USER_NAME; or set -g SA_USER_NAME "участнику"
set -q SA_LANG; or set -g SA_LANG ru
set -q SA_WHISPER_URL; or set -g SA_WHISPER_URL "http://127.0.0.1:8080/inference"
set -q SA_OLLAMA_URL; or set -g SA_OLLAMA_URL "http://127.0.0.1:11434/api/generate"

function sa_config_load --description "Читает ~/.config/study-agent/config.env, если он есть"
    set -l f ~/.config/study-agent/config.env
    test -f $f; or return 0
    for line in (cat $f)
        set line (string trim -- $line)
        # Пустые строки и комментарии пропускаем.
        if test -z "$line"; or string match -q '#*' -- $line
            continue
        end
        set -l kv (string split -m1 '=' -- $line)
        test (count $kv) -eq 2; or continue
        set -l key (string trim -- $kv[1])
        set -l val (string trim -- $kv[2])
        # Кавычки вокруг значения -- дело вкуса, снимаем и те и другие.
        set val (string trim -c '"\'' -- $val)
        # ~ в конфиге писать удобнее, чем полный путь.
        set val (string replace -r '^~' $HOME -- $val)
        switch $key
            case SA_VAULT_DIR SA_STUDY_SUBDIR SA_USER_NAME SA_LANG SA_WHISPER_URL SA_OLLAMA_URL
                set -g $key $val
        end
    end
end

sa_config_load

# Готовый путь до папки с учебными сессиями -- им пользуются почти все скрипты.
set -g SA_STUDY_DIR "$SA_VAULT_DIR/$SA_STUDY_SUBDIR"
