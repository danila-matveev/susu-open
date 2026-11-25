# Table for editor runs written by `susu-bench transcribe --style ...`: one row per run file.
# usage: python3 -I tools/stt-eval/editor_table.py RUN.json [RUN.json ...] [--dict FILE]
# Columns: names (R1), R4, R5 (check.py, dictionary = hint.txt + extra terms), R5 added by the editor
# (Latin words in the final text that were not in the STT text and not in the dictionary), added latency
# (median / p90 ms), model answers used, rephrasings (final text differs from step 1 by words that are not dictionary terms).
import argparse, difflib, json, os, statistics, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from evaluate import load, norm
from check import check, dictionary, LATIN


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--set", default=os.environ.get("SUSU_TESTSET", os.path.expanduser("~/Projects/susu/research-private/stt")))
    ap.add_argument("--dict", help="extra terms JSON from `susu-bench wispr-dictionary` (default: <set>/dictionary.json)")
    a = ap.parse_args()
    refs, clips = load(a.set)
    terms = dictionary(f"{a.set}/hint.txt")
    extra = a.dict or f"{a.set}/dictionary.json"
    if os.path.exists(extra):
        d = json.load(open(extra))
        terms += [w for w in d.get("words", []) + [r["replacement"] for r in d.get("replacements", [])] if len(w) > 1 and "," not in w]
    term_words = {w for t in terms for w in norm(t)}
    print(f"{'run':44} {'R1 names':>8} {'R4':>3} {'R5':>3} {'R5 new':>6} {'med ms':>6} {'p90 ms':>6} {'used':>5} {'rephr':>5} {'rejected raw':>12}")
    for path in a.runs:
        hyps = json.load(open(path))
        m = check(refs, clips, hyps, terms)
        ms = sorted(h["editor_ms"] for h in hyps.values() if "editor_ms" in h)
        used = sum(1 for h in hyps.values() if h.get("used"))
        new5 = rephr = rej = 0
        for h in hyps.values():
            if "rules_text" not in h:
                continue
            before, after = norm(h["rules_text"]), norm(h["text"])
            known = set(before) | term_words
            new5 += sum(1 for w in after if LATIN.match(w) and w not in known)
            sm = difflib.SequenceMatcher(None, before, after, autojunk=False)
            for op, i1, i2, j1, j2 in sm.get_opcodes():
                if op != "equal" and not all(w in term_words for w in after[j1:j2]):
                    rephr += 1
                    break
            rej += h.get("outcome", "").startswith("rejected: changedWords")
        med = statistics.median(ms) if ms else 0
        p90 = ms[min(len(ms) - 1, int(len(ms) * 0.9))] if ms else 0
        print(f"{os.path.basename(path)[:-5]:44} {m['names']:8.1%} {len(m['r4']):3} {len(m['r5']):3} {new5:6} {med:6.0f} {p90:6.0f} {used:3}/{len(hyps):<2} {rephr:5} {rej:12}")


if __name__ == "__main__":
    main()
