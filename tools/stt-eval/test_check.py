# Self-check for check.py on a tiny synthetic set. usage: python3 -I tools/stt-eval/test_check.py
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check import check

refs = {"a": {"text": "Пишу в Телеграме про Claude Code", "keys": ["Claude Code"]},
        "b": {"text": "How much money is on Telega.in", "keys": ["Telega.in"]},
        "c": {"text": "Просто обычная фраза", "keys": []}}
clips = {"a": {"lang": "ru"}, "b": {"lang": "en"}, "c": {"lang": "ru"}}
terms = ["Claude Code", "Telegram", "TELOWAY", "Telega.in", "Notion"]

m = check(refs, clips, {"a": {"text": "Пишу в Telegram про Claude Code", "sec": 0.5},
                        "b": {"text": "How much money is on TELOWAY", "sec": 0.7},
                        "c": {"text": "Просто обычная фраза Notion", "sec": 0.4}}, terms)
assert m["names"] == 0.5, m["names"]                      # Claude Code hit, Telega.in missed
assert m["r4"] == [("b", "TELOWAY"), ("c", "Notion")], m["r4"]  # Telegram is a transliteration, not a misfire
assert m["r3"][:2] == (1, 1)
assert m["sec"] == 0.5

m = check(refs, clips, {"b": {"text": "Сколько денег на Telega.in"}}, terms)
assert m["r3"][2] == ["b"]                                # English clip came back in Russian
refs2 = {"d": {"text": "Открой Клод Код", "keys": []}}
m = check(refs2, {"d": {"lang": "ru"}}, {"d": {"text": "Открой Claude Code"}}, terms)
assert m["r4"] == [], m["r4"]                              # multi-word name said in Cyrillic is not a misfire
print("check.py self-test ok")
