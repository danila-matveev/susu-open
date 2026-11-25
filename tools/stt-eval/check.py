# Pass/fail gate for one run against thresholds. Exit code 1 if any check fails.
# usage: python3 -I tools/stt-eval/check.py RUN.json [--set DIR] [--names 0.90] [--wer-ru 0.12] [--sec 0.6] [--r5-max 0]
# Always checked: R3 (English clips stay English) and R4 (dictionary words never appear where they were not said).
import argparse, json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir on 3.11+
from evaluate import load, norm, score

LATIN = re.compile(r"^[a-z][a-z0-9]*$")


def dictionary(path):
    """hint.txt: optional 'lead-in:' then comma-separated terms."""
    text = open(path).read().strip()
    text = text.split(":", 1)[1] if ":" in text else text
    return [t.strip().rstrip(".") for t in text.split(",") if t.strip()]


TR = dict(zip("абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
              ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "i", "k", "l", "m", "n", "o", "p", "r", "s", "t",
               "u", "f", "h", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya"]))


def translit(w):
    return "".join(TR.get(c, c) for c in w)


def skeleton(words):
    """Consonant skeleton across scripts: Клод Код and Claude Code both give 'kldkd'."""
    return re.sub(r"[aeiouy]", "", translit("".join(words)).replace("c", "k"))


def said(ref, seq):
    """Term counts as said if the reference has it, or the same words in Cyrillic
    (Телеграме -> Telegram, Клод Код -> Claude Code). ponytail: skeleton prefix match, tighten if it hides real misfires."""
    if contains(ref, seq):
        return True
    head = skeleton(seq)
    n = len(seq)
    return len(head) >= 3 and any(skeleton(ref[i:i + n]).startswith(head) for i in range(len(ref) - n + 1))


def contains(words, seq):
    return any(words[i:i + len(seq)] == seq for i in range(len(words) - len(seq) + 1))


def latin_share(t):
    letters = [c for c in t if c.isalpha()]
    return sum("a" <= c.lower() <= "z" for c in letters) / len(letters) if letters else 0


def check(refs, clips, hyps, terms):
    """-> dict of metrics plus offending clip lists."""
    en = [i for i in refs if clips[i]["lang"] == "en"]
    ru = [i for i in refs if clips[i]["lang"] != "en"]
    wer, names, sec = score(refs, hyps)
    r3_bad = [i for i in en if latin_share(hyps.get(i, {}).get("text", "")) < 0.5]
    term_seqs = [(t, norm(t)) for t in terms if norm(t)]
    dict_words = {w for _, s in term_seqs for w in s}
    r4, r5 = [], []
    for i in refs:
        ref, hyp = norm(refs[i]["text"]), norm(hyps.get(i, {}).get("text", ""))
        r4 += [(i, t) for t, s in term_seqs if contains(hyp, s) and not said(ref, s)]
        r5 += [(i, w) for w in hyp if LATIN.match(w) and w not in ref and w not in dict_words]
    return {"wer": wer, "wer_ru": score(refs, hyps, ru)[0], "names": names, "sec": sec,
            "r3": (len(en) - len(r3_bad), len(en), r3_bad), "r4": r4, "r5": r5}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--set", default=os.environ.get("SUSU_TESTSET", os.path.expanduser("~/Projects/susu/research-private/stt")))
    ap.add_argument("--dict", help="dictionary terms file (default: <set>/hint.txt)")
    ap.add_argument("--names", type=float)
    ap.add_argument("--wer-ru", type=float)
    ap.add_argument("--sec", type=float)
    ap.add_argument("--r5-max", type=int)
    ap.add_argument("--partial", action="store_true", help="score only the clips in the run (a run cut short on purpose)")
    a = ap.parse_args()
    refs, clips = load(a.set)
    run = json.load(open(a.run))
    if a.partial: refs = {i: r for i, r in refs.items() if i in run}
    m = check(refs, clips, run, dictionary(a.dict or f"{a.set}/hint.txt"))
    ok_r3, n_en, bad_r3 = m["r3"]
    rows = [("names", f"{m['names']:.1%}", a.names and f">= {a.names:.0%}", a.names is None or round(m["names"], 2) >= a.names),
            ("WER ru", f"{m['wer_ru']:.1%}", a.wer_ru and f"<= {a.wer_ru:.1%}", a.wer_ru is None or m["wer_ru"] <= a.wer_ru),
            ("WER all", f"{m['wer']:.1%}", None, True),
            ("median sec", str(m["sec"] and round(m["sec"], 2)), a.sec and f"<= {a.sec}", a.sec is None or (m["sec"] or 99) <= a.sec),
            ("R3 English kept", f"{ok_r3}/{n_en}", f"{n_en}/{n_en}", ok_r3 == n_en),
            ("R4 dictionary misfires", str(len(m["r4"])), "0", not m["r4"]),
            ("R5 extra Latin words", str(len(m["r5"])), a.r5_max is not None and f"<= {a.r5_max}", a.r5_max is None or len(m["r5"]) <= a.r5_max)]
    for name, fact, need, ok in rows:
        print(f"{name:24} {fact:>8}  {need or '':>8}  {'ok' if ok else 'FAIL'}")
    if bad_r3: print("R3 translated:", ", ".join(bad_r3))
    if m["r4"]: print("R4:", ", ".join(f"{i}:{t}" for i, t in m["r4"]))
    if m["r5"]: print("R5:", ", ".join(f"{i}:{w}" for i, w in m["r5"]))
    sys.exit(0 if all(r[3] for r in rows) else 1)


if __name__ == "__main__":
    main()
