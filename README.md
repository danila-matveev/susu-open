# Susu

A personal agent that lives on your Mac: voice dictation into any app, call recording with transcripts and summaries, and a voice button that turns speech into tasks and calendar events.

Built first for Russian speech with English words mixed in. Open source.


## Languages

Dictation goes to Groq Whisper `large-v3-turbo` with automatic language detection and a hint made of your dictionary terms. We test it on 15 languages with synthetic macOS voices. Each language gets a plain sentence with three product names and a sentence that switches to English halfway. Real voices will score worse. Last run: 13.11.2026, `tools/stt-eval/multilang/`.

| Language | Word error, plain | Word error, mixed with English | Names (of 3) | English part kept |
|---|---|---|---|---|
| English | 0% | 14% | 3 | yes |
| Russian | 8% | 8% | 2 | yes |
| Spanish | 15% | 14% | 1 | yes |
| Portuguese | 7% | 6% | 2 | yes |
| German | 8% | 13% | 3 | yes |
| French | 8% | 20% | 3 | yes |
| Italian | 8% | 8% | 2 | yes |
| Polish | 9% | **58%** | 2 | yes |
| Ukrainian | **33%** | **69%** | 1 | yes |
| Turkish | **56%** | 29% | 2 | yes |
| Indonesian | 8% | 20% | 2 | yes |
| Hindi | 20% | **80%** | 2 | **no** |
| Japanese | 0% | 9% | 3 | yes |
| Chinese | 3% | 0% | 3 | yes |
| Korean | 22% | 23% | 3 | yes |

Japanese and Chinese are scored by characters. The language was detected correctly in 15 of 15. Median latency was 0.51 s. Weak spots are Turkish and Ukrainian, plus Polish and Hindi when English is mixed in. In those languages the English half of a sentence comes back garbled or transliterated. Without a network connection, only Russian (GigaAM) and 25 European languages (Parakeet) will work.

## Лицензия

Код распространяется по лицензии GNU AGPL-3.0, полный текст в файле `LICENSE`.
