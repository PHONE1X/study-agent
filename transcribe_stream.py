#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Потоковая транскрипция: один непрерывный parec + резка по границам фраз.

ИСТОРИЯ ПЕРЕПИСОК

Версия 1 (transcribe_loop.fish) резала звук вслепую на куски по 6 секунд.
Слово на стыке разрушалось в обеих половинах: 79% строк обрывались посреди
предложения.

Версия 2 (эта же программа, окна 15 с с перекрытием 3 с) стало лучше, но
осталось две беды, обе найдены на живом транскрипте.

1. ПУНКТУАЦИЯ ИСЧЕЗЛА. В whisper передавался prompt -- хвост предыдущей
   строки. Whisper подражает СТИЛЮ prompt'а. Стоило одному окну выдать текст
   без запятых, как этот текст становился prompt'ом для следующего окна, то
   без запятых выходило и оно. Петля с обратной связью: через несколько минут
   пунктуация пропадала полностью и больше не возвращалась. Замер на одном и
   том же куске звука:

       prompt пустой   -> «Вот, наконец-то начал тратиться стамина.
                          Тратится стамина. Вот я в комбате.»
       prompt без .,   -> «вот наконец начал тратиться стамина тратится
                          стамина вот я в комбате»
       prompt с .,     -> «Вот, наконец-то начал тратиться стамина.
                          Тратится стамина. Вот я в комбате.»

   Портилась не только пунктуация: «наконец-то» превращалось в «наконец»,
   «со стаминой» -- в «со стамины». Теперь prompt проверяется: если в нём
   мало знаков препинания, он не используется, вместо него идёт образец с
   нормальной пунктуацией.

2. РЕЗКА ВСЛЕПУЮ ОСТАВАЛАСЬ. Окно кончалось где попало, последние слова
   whisper домысливал («статов на стрелы» вместо «статов на старте»), а
   склейка их не убирала: она искала точное совпадение хвоста с началом, а
   испорченное слово совпадать не могло.

   Теперь окно не режется вслепую вообще. Whisper возвращает границы фраз
   (response_format=verbose_json). Последняя фраза окна отбрасывается -- она
   почти наверняка обрезана -- и следующее окно начинается ровно там, где
   кончилась последняя ЦЕЛАЯ фраза. Слово на границе больше не возникает.

РАЗМЕР ОКНА

30 секунд -- родной контекст whisper: кодировщик всё равно дополняет вход до
30 секунд, поэтому окно 30 с считается ровно столько же, сколько окно 15 с,
но модель видит вдвое больше контекста. На RX 6800 окно считается за ~0.7 с,
то есть в 40 раз быстрее реального времени. Запаса вагон.

ГАЛЛЮЦИНАЦИИ НА ТИШИНЕ

Whisper на тишине выдумывает текст -- у русской модели это чаще всего
«Продолжение следует...». Отбрасываются по списку, но только при совпадении
со ВСЕЙ строкой: фраза может прозвучать и по-настоящему. Вдобавок сервер
запущен с -sns (suppress non-speech tokens), это давит их в самом декодере.
"""

import io
import json
import os
import re
import subprocess
import sys
import time
import wave

RATE = 16000
CHANNELS = 1
SAMPWIDTH = 2
BPS = RATE * CHANNELS * SAMPWIDTH  # байт в секунде потока

WINDOW_SEC = 30.0        # родной контекст whisper
MIN_ADVANCE_SEC = 4.0    # страховка: не топтаться на месте, если фразы куцые
MAX_ADVANCE_SEC = 29.0   # страховка: не проскочить конец окна
EDGE_GUARD_SEC = 0.30    # отступ назад от границы фразы -- метки времени whisper
                         # неточны на десятые доли, лучше повторить чуть звука,
                         # чем срезать начало следующего слова
MAX_BUFFER_SEC = 180     # если вдруг отстали от потока -- выбросить самое старое

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sa_config

WHISPER_URL = sa_config.get("SA_WHISPER_URL")
DEVICE = sa_config.get("SA_CAPTURE_DEVICE")
LANG = sa_config.get("SA_LANG")
HOME = os.path.expanduser("~")
TRANSCRIPT = os.path.join(HOME, ".local/share/study-agent/transcript.log")
TMP_WAV = "/tmp/study-agent-window.wav"

WINDOW_BYTES = int(WINDOW_SEC * BPS)

# Образец стиля для whisper: обычная русская речь с запятыми и точками.
# Подставляется, когда своего хорошего контекста ещё нет.
PRIMER = ("Итак, продолжаем. Смотрите, что здесь происходит: сначала одно, "
          "потом другое. Понятно, да? Хорошо, идём дальше.")

HALLUCINATIONS = {
    "продолжение следует",
    "спасибо за просмотр",
    "субтитры сделал dimatorzok",
    "субтитры создавал dimatorzok",
    "субтитры делал dimatorzok",
    "субтитры",
    "редактор субтитров",
    "корректор",
    "спасибо",
    "продолжение",
}

_punct = re.compile(r"[^\w\s]", re.UNICODE)
_space = re.compile(r"\s+", re.UNICODE)


def norm(s):
    """Нормализация для сравнения: без пунктуации, в нижнем регистре."""
    return _space.sub(" ", _punct.sub(" ", s.lower())).strip()


def is_hallucination(text):
    n = norm(text)
    if not n:
        return True
    if n in HALLUCINATIONS:
        return True
    # «Продолжение следует... Продолжение следует...» -- то же самое, повторённое
    # моделью несколько раз подряд внутри одной строки.
    words = n.split()
    for h in HALLUCINATIONS:
        hw = h.split()
        if len(hw) >= 2 and words and len(words) % len(hw) == 0:
            if all(words[i:i + len(hw)] == hw for i in range(0, len(words), len(hw))):
                return True
    return False


def punct_ok(s):
    """
    Годится ли текст как prompt для whisper.

    Whisper подражает стилю prompt'а, поэтому текст без пунктуации в prompt'е
    порождает текст без пунктуации на выходе -- и дальше по кругу. Нормальная
    речь даёт примерно один знак на 6-8 слов; порог 1 на 14 заведомо мягкий,
    он ловит только настоящий развал.
    """
    if not s:
        return False
    words = len(s.split())
    marks = sum(s.count(c) for c in ".,!?;:")
    return words >= 8 and marks >= words / 14.0


def build_prompt(prev_text):
    tail = (prev_text or "")[-250:]
    if punct_ok(tail):
        return tail
    return PRIMER


def tokens(s):
    """Список пар (как в тексте, нормализовано); чистая пунктуация выбрасывается."""
    out = []
    for t in s.split():
        n = norm(t)
        if n:
            out.append((t, n))
    return out


def strip_overlap(prev, cur, max_words=30, tail_slack=4, min_match=3):
    """
    Подстраховка от повтора на стыке окон.

    Резка по границам фраз должна убрать повторы сама, но метки времени
    whisper неточны, и EDGE_GUARD_SEC намеренно возвращает нас чуть назад --
    иногда пара слов повторяется. Ищем самый длинный хвост prev, совпадающий
    с началом cur.

    tail_slack: последние слова prev могли быть распознаны иначе, поэтому
    разрешаем откинуть до 4 слов с конца prev перед сравнением. Именно этого
    не хватало прошлой версии -- одно испорченное слово в конце блокировало
    совпадение целиком, и в лог уходил дубль всей фразы.

    Совпадением считаем 75% одинаковых слов, а не все: whisper может расслышать
    одно слово из десяти иначе. Если совпадения нет -- не режем ничего:
    лучше редкий повтор, чем потерянные слова.
    """
    if not prev or not cur:
        return cur
    pw = [n for _, n in tokens(prev)]
    ct = tokens(cur)
    cw = [n for _, n in ct]
    if not pw or not cw:
        return cur
    best_k = 0
    for drop in range(tail_slack + 1):
        end = len(pw) - drop
        if end <= 0:
            break
        limit = min(max_words, end, len(cw))
        for k in range(limit, min_match - 1, -1):
            a, b = pw[end - k:end], cw[:k]
            same = sum(1 for x, y in zip(a, b) if x == y)
            if same >= max(min_match, int(k * 0.75)):
                if k > best_k:
                    best_k = k
                break
    if best_k < min_match:
        return cur
    return " ".join(t for t, _ in ct[best_k:]).strip()


def to_wav(pcm):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(CHANNELS)
        w.setsampwidth(SAMPWIDTH)
        w.setframerate(RATE)
        w.writeframes(pcm)
    return buf.getvalue()


def transcribe(pcm, prompt):
    """Возвращает список фраз [(start_sec, end_sec, text)]."""
    with open(TMP_WAV, "wb") as f:
        f.write(to_wav(pcm))
    cmd = [
        "curl", "-s", "-X", "POST", WHISPER_URL,
        "-F", "file=@" + TMP_WAV,
        "-F", "language=" + LANG,
        # verbose_json нужен ради границ фраз -- по ним режется окно.
        "-F", "response_format=verbose_json",
        # ВАЖНО. whisper-server на /inference молча берёт max_len = 60 (в
        # --help у CLI написан 0, у сервера умолчание другое) и рвёт фразу
        # ровно на 58-м символе, посреди слова: «телепорт» / «нуться в пещеру».
        # Именно отсюда брались обрывки в транскрипте. max_len=0 не помогает --
        # сервер считает это «не задано». Нужно явное большое число.
        "-F", "max_len=800",
        # Подстраховка: если предел всё же сработает, резать по словам.
        "-F", "split_on_word=true",
        # temperature=0 заметно снижает выдумывание на тихих участках.
        "-F", "temperature=0",
        "--form-string", "prompt=" + (prompt or ""),
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, timeout=120)
    except subprocess.TimeoutExpired:
        print("TRANSCRIBE: whisper не ответил за 120 с", file=sys.stderr, flush=True)
        return []
    raw = out.stdout.decode("utf-8", "replace").strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except ValueError:
        print("TRANSCRIBE: неразобранный ответ whisper: %r" % raw[:120],
              file=sys.stderr, flush=True)
        return []
    segs = []
    for s in data.get("segments") or []:
        text = (s.get("text") or "").strip()
        if not text:
            continue
        try:
            t0 = float(s.get("start", 0.0))
            t1 = float(s.get("end", 0.0))
        except (TypeError, ValueError):
            continue
        segs.append((t0, t1, text))
    return segs


def start_parec():
    return subprocess.Popen(
        ["parec", "--device=" + DEVICE, "--rate=" + str(RATE),
         "--channels=" + str(CHANNELS), "--format=s16le", "--raw"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )


def main():
    os.makedirs(os.path.dirname(TRANSCRIPT), exist_ok=True)
    print("Transcription stream started (window=%.0fs, резка по границам фраз)."
          % WINDOW_SEC, flush=True)
    print("Writing to " + TRANSCRIPT, flush=True)

    proc = start_parec()
    buf = bytearray()
    consumed = 0          # сколько байт потока уже ушло за левый край окна
    stream_t0 = time.time()
    prev_text = ""        # последняя выданная фраза -- и prompt, и база для склейки

    while True:
        block = proc.stdout.read(BPS // 4) if proc.stdout else b""
        if not block:
            # parec умер: обычно вместе с исчезновением agent-capture.
            print("TRANSCRIBE: поток оборвался, перезапускаю parec через 2 с",
                  file=sys.stderr, flush=True)
            try:
                proc.kill()
            except Exception:
                pass
            time.sleep(2)
            proc = start_parec()
            buf.clear()
            stream_t0 = time.time()
            consumed = 0
            continue

        buf.extend(block)
        if len(buf) < WINDOW_BYTES:
            continue

        # Если распознавание почему-то отстало от потока -- выбросить старое,
        # иначе транскрипт будет всё сильнее отставать от видео.
        if len(buf) > MAX_BUFFER_SEC * BPS:
            drop = len(buf) - int(MAX_BUFFER_SEC * BPS)
            del buf[:drop]
            consumed += drop
            print("TRANSCRIBE: отстали от потока, пропущено %.0f с" % (drop / BPS),
                  file=sys.stderr, flush=True)

        window = bytes(buf[:WINDOW_BYTES])
        win_t0 = stream_t0 + consumed / BPS
        segs = transcribe(window, build_prompt(prev_text))

        if not segs:
            # Тишина или whisper ничего не нашёл -- двигаемся на всё окно.
            advance = MAX_ADVANCE_SEC
        else:
            # Последняя фраза почти наверняка обрезана краем окна -- не выдаём
            # её, а начинаем следующее окно с её начала. Если фраза всего одна,
            # выдать её всё же надо, иначе поток встанет.
            emit = segs[:-1] if len(segs) > 1 else segs
            for t0, t1, text in emit:
                if is_hallucination(text):
                    print("TRANSCRIBE: [%s] отброшена галлюцинация на тишине: %r"
                          % (time.strftime("%H:%M:%S", time.localtime(win_t0 + t0)),
                             text[:60]), flush=True)
                    continue
                merged = strip_overlap(prev_text, text)
                if not merged.strip():
                    continue
                ts = time.strftime("%H:%M:%S", time.localtime(win_t0 + t0))
                line = "[%s] %s" % (ts, merged)
                with open(TRANSCRIPT, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
                print(line, flush=True)
                prev_text = merged

            advance = emit[-1][1] - EDGE_GUARD_SEC

        advance = max(MIN_ADVANCE_SEC, min(MAX_ADVANCE_SEC, advance))
        step = int(advance * BPS)
        del buf[:step]
        consumed += step


if __name__ == "__main__":
    main()
