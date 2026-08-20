# study-agent

A fully local pipeline that listens to one application's audio, transcribes it,
and writes structured notes into an Obsidian vault **while the lecture is still
running**.

No cloud, no API keys, no subscription. Audio never leaves the machine:
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) does speech recognition,
[Ollama](https://ollama.com) runs the language model.

It was built for eight-hour conference streams and multi-day courses: start it,
walk away, and at any moment open the vault and read what has been said so far.

---

## What it produces

For each session, one folder in the vault:

```
Обучение/2026-08-20 SSH and DevOps/
├── Обзор.md          index of the session, links to every segment
├── Транскрипт.md     full transcript, updated every 3 seconds
├── 01 <topic>.md     notes for the first topic
├── 02 <topic>.md     a new file each time the subject changes
├── Конспект.md       connected summary + self-check questions
└── Обращения.md      appears only if someone addressed you by name
```

Three layers on purpose. The transcript is everything that was said, in order,
readable as text. The segments are notes per topic. The summary is the thing you
revise from.

Timing, measured on a live run:

| When | What appears |
| --- | --- |
| ~40 seconds after start | session folder, index, first segment |
| every 3 seconds | transcript grows, line by line |
| every 2 minutes | notes appended; new file when the topic changes |
| every ~6 minutes | summary rebuilt from everything so far |
| on `agent stop` | summary rebuilt one final time |

## Being addressed by name

If your name is spoken, you get a desktop notification immediately, and a second
one a few seconds later containing **the reconstructed question and a draft
answer**.

The question is rarely in the same sentence as the name. `"...how often do we
rotate keys? ... Arthur, what do you think?"` — the question is the first half,
and that is what gets extracted.

Every draft answer carries its source: from the conversation, from the notes of
a *previous* session, or **not in the materials at all**. The last one is an
allowed answer. A draft gets read aloud as your own words, so an invented fact is
worse than no answer — see [docs/FINDINGS.md](docs/FINDINGS.md#answers-must-carry-a-source).

## Requirements

- Linux with **PipeWire** (`pw-link`, `pw-dump`, `parec`) — audio is branched at
  the graph level, so the application keeps playing to your speakers untouched
- **fish** shell
- `systemd --user`
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) built with GPU support,
  plus `ggml-large-v3-turbo` and a Silero VAD model
- [Ollama](https://ollama.com) with a model that follows instructions (`qwen3:8b`
  by default)
- `jq`, `curl`, `python3`, `notify-send`

Developed on Arch Linux with an AMD RX 6800 (Vulkan). A 30-second audio window
takes ~0.65 s to transcribe there — roughly 40x faster than real time.

## Install

```bash
git clone https://github.com/<you>/study-agent.git ~/.local/bin/study-agent
cd ~/.local/bin/study-agent

mkdir -p ~/.config/study-agent
cp config.example.env ~/.config/study-agent/config.env
$EDITOR ~/.config/study-agent/config.env      # vault path, your name

cp trigger_words.example.txt trigger_words.txt
$EDITOR trigger_words.txt                      # names that should alert you

cp systemd/*.service ~/.config/systemd/user/
$EDITOR ~/.config/systemd/user/whisper-server.service   # model paths
systemctl --user daemon-reload
```

Do not `systemctl enable` anything. The services are started on demand by
`agent start` and stopped by `agent stop`.

## Use

```bash
agent start          # pick session, pick which application to capture
agent status         # services, capture source, session, transcript size
agent stop           # stop capture, build the final summary
```

Other commands: `agent mute` / `unmute` (stop hearing the audio while it keeps
recording), `agent interval <sec>`, `agent model <name>`, `agent logs`,
`agent probe` (dump the audio graph when something does not add up).

## Configuration

`~/.config/study-agent/config.env`, read by both the fish and the Python parts:

| Key | Meaning |
| --- | --- |
| `SA_VAULT_DIR` | Obsidian vault root |
| `SA_STUDY_SUBDIR` | folder inside the vault for sessions |
| `SA_USER_NAME` | how prompts refer to you |
| `SA_LANG` | recognition language |
| `SA_WHISPER_URL`, `SA_OLLAMA_URL` | service endpoints |

## Limitations, stated plainly

- **The prompts are written in Russian and the notes come out in Russian.**
  `SA_LANG` changes what whisper listens for, but the note-writing prompts in
  `cold_path_daemon.fish`, `make_summary.fish` and `draft_answer.fish` are
  Russian text. Another language means translating them. Everything else is
  language-agnostic.
- **PipeWire only.** The capture branches a copy of the stream with `pw-link`.
  There is a fallback that moves the stream instead, but no PulseAudio or
  CoreAudio support.
- **Audio capture is the fragile part.** Starting a different video creates a new
  stream; the watchdog re-attaches automatically only when the application has
  exactly one stream playing. With two it refuses to guess rather than risk
  recording the wrong thing.
- **Note quality is bounded by the local model.** An 8B model still copies words
  it did not understand and occasionally drops the point of a sentence. There is
  a deterministic filter between the model and the vault that rejects bullets
  unsupported by the source text, but it cannot fix a bullet that is merely
  shallow.
- `agent start` is interactive by design — it asks which audio to capture — so it
  cannot be driven from a script.

## Notes on the internals

[docs/FINDINGS.md](docs/FINDINGS.md) documents the non-obvious things this
project ran into: an undocumented server default that cut words in half, a
feedback loop that silently destroyed punctuation, and why windows are cut at
phrase boundaries instead of on a timer. Those cost days to find and are worth
reading before touching the transcription path.

## License

MIT — see [LICENSE](LICENSE).
