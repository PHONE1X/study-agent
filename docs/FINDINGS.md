# Findings

Things that were expensive to discover. Most of them are not documented anywhere
obvious, and every one of them was found by running the pipeline and reading the
output — never by reading the code.

---

## whisper-server silently truncates segments at 60 characters

`whisper-server` from whisper.cpp applies a default `max_len` on the
`/inference` endpoint and cuts each segment at **character 58, mid-word**:

```
| что в этих руинах есть ящик, который позволит нам телепорт|
|нуться в пещеру рядом с локоть для того,|
| чтобы скип сделать. Нам нужно отправиться сейчас в Храм Чум|
|ы. Есть две причины, почему нам нужно|
```

The CLI `--help` documents `-ml, --max-len [0] maximum segment length in
characters`, and zero means unlimited. The HTTP endpoint does not behave that
way.

**Passing `max_len=0` does not help** — the server treats it as "not set" and
falls back to its own default. It needs an explicit large value:

```
-F max_len=800
-F split_on_word=true    # belt and braces, if a limit does fire, break on a word
```

With that, the same audio produces whole phrases with natural boundaries.

This is easy to miss because it is content-dependent: audio with clear pauses
comes back correctly segmented, so a quick test can pass while continuous speech
is being shredded.

---

## Feeding your own output back as `prompt` destroys punctuation

Streaming transcription usually passes the previous chunk's text into the next
request as context, so terminology stays consistent. whisper does use it — but it
imitates the **style** of the prompt, including punctuation.

The failure is a feedback loop. One window returns text without commas; that text
becomes the prompt for the next window; that window also drops punctuation. After
a few minutes the transcript is one long unpunctuated stream and it never
recovers.

Same 15 seconds of audio, three runs, everything else identical:

| `prompt` | Output |
| --- | --- |
| empty | `Вот, наконец-то начал тратиться стамина. Вот я в комбате.` |
| unpunctuated text | `вот наконец начал тратиться стамина вот я в комбате` |
| punctuated text | `Вот, наконец-то начал тратиться стамина. Вот я в комбате.` |

It is not only punctuation. `наконец-то` degraded to `наконец`, and the
grammatically correct `со стаминой` became `со стамины`. Proper nouns suffered
too: English game terms that came out correctly as `Deathpocker` and `Limgrave`
with a clean prompt were mangled into phonetic Russian without one.

**Fix:** check the text before using it as a prompt. If its punctuation density
is below roughly one mark per 14 words, discard it and use a fixed, correctly
punctuated priming sentence instead. See `punct_ok()` in `transcribe_stream.py`.

---

## Cut windows at phrase boundaries, not on a timer

Fixed-size windows cut words in half. The obvious mitigation — overlapping
windows plus text-level de-duplication — helps but does not solve it, because
whisper *guesses* the word it only half heard. The two windows then disagree
about the boundary word, exact-match de-duplication finds nothing, and the whole
phrase is emitted twice:

```
...третье у него очень много полезных статов на стрелы
третье у него очень много полезных статов на старте а нам на старте...
```

`стрелы` is the corrupted guess; `старте` is what was actually said. A single
wrong word at the tail blocked the overlap match entirely.

**Fix:** ask for `response_format=verbose_json`, which returns phrase boundaries.
Discard the last phrase of each window — it is almost certainly cut — and start
the next window exactly where the last *complete* phrase ended. No blind cut, no
guessed boundary word, and no overlap to de-duplicate.

Measured across versions on the same source:

| Version | Line ends at a sentence | Line starts mid-word |
| --- | --- | --- |
| 6 s blind chunks | 19% | 80% |
| 15 s windows, 3 s overlap | 21% | 82% |
| phrase boundaries + punctuated prompt | **90%** | **18%** |

---

## A 30-second window costs the same as a 15-second one

whisper's encoder pads its input to 30 seconds regardless. A 15-second window
buys nothing in speed and halves the context the model can use. Use the full 30.

Beam search is similarly underused. On an RX 6800, `-bs 5 -bo 5` transcribes a
30-second window in ~0.65 s — about 40x faster than real time. Accuracy was
simply being left on the table.

`-sns` (suppress non-speech tokens) additionally reduces the hallucinations
whisper produces on silence.

---

## Never put copyable content in a prompt

The note-writing prompt contained an example of the desired phrasing, with a real
number in it — roughly *"not «it weighs 3.8 litres», but «case volume — 3.8
litres»"*.

The model copied the example out of the instructions and wrote it into the notes
as a fact. It appeared in two different note files of a session about an entirely
different subject. The string existed nowhere in the transcript.

**Fix:** instructions describe *what to do* and never show *what it looks like*.
No numbers, no names, no ready-made phrasings anywhere in a prompt.

And because a prompt is a request rather than a guarantee, there is now a
deterministic filter (`ground_bullets.py`) between the model and the vault. A
bullet is rejected if fewer than 40% of its content words appear in the source
fragment, if it repeats a bullet already written, or if it looks like a scatter of
numbers from a chat rather than content. Stemming is the first five characters of
each word — crude, but Russian inflects everything and a real lemmatiser is a
dependency this does not need.

Spoken numerals are expanded to digits before comparison, otherwise a correct
bullet saying `2.5 seconds` looks invented when the speaker said
*"две с половиной"*.

---

## Answers must carry a source

The feature that notifies you when someone says your name also drafts an answer.
Asked *"how often do we rotate keys on prod per the policy?"* — a question whose
answer appeared nowhere — the model replied:

> Rotation on prod is performed **every 90 days** per the policy.

Nothing in the conversation or the notes contained that number. A draft answer
gets read out loud as your own words, which makes an invented fact considerably
worse here than in a note.

**Fix:** the model must return a `source` field — from the conversation, from
previous sessions' notes, or **nowhere** — and "nowhere" is an allowed answer,
with a short honest line to say instead. The source is shown in the notification
and in the vault entry. It is also forbidden to state numbers, dates, versions or
names absent from the materials, and forbidden to assign responsibility to the
user unless the text does.

Searching previous sessions matters on its own: a question on day 7 of a course
is often answered by day 2's notes. `find_in_notes.py` does a word-overlap search
across every session except the current one.

**One prompt could not do all of this.** Extraction and answering were originally
a single call. Once notes and sourcing rules were added, an 8B model stopped
coping — the extracted question degraded into the raw line containing the name,
and the source was labelled at random. Splitting it into two focused calls
restored both. Latency did not suffer: the first notification fires before any of
this runs.

---

## Operational traps

**fish parses a script fully at launch.** Editing a daemon's prompt has no effect
on the running process. Several prompt changes were silently never executed until
this was noticed. Always restart the unit after editing.

**Switching videos breaks more than capture.** Playing the next video makes the
browser close the old audio stream and open a new one, with a new node id and a
new serial. Anything holding the old identifier breaks — including `agent mute`,
which moves the stream by that identifier and fails with a generic error. The
watchdog now re-attaches and, importantly, **updates the stored serial**;
otherwise capture would resume while mute stayed broken.

**Thresholds must be expressed in the right unit.** The session folder is only
created once enough speech has accumulated to name it. That gate counted *lines*.
When the transcription window grew from 6 to 15 seconds, lines became longer and
fewer, and the same threshold silently doubled the wait to two minutes. It counts
characters now, which is independent of window size.
