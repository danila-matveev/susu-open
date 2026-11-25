# WER-vs-reference + key-term hit rate + median latency for every run against refs.json.
# usage: python3 -I tools/stt-eval/evaluate.py "$SUSU_TESTSET"
# Test set layout: refs.json, clips/clips.json, runs/*.json (see README.md).
import glob, json, os, re, statistics, sys

FILL = {"э", "ээ", "эээ", "эм", "м", "мм", "ммм", "ну", "типа", "uh", "um"}
NUM = dict(zip("ноль один одна два две три четыре пять шесть семь восемь девять десять одиннадцать двенадцать тринадцать четырнадцать пятнадцать шестнадцать семнадцать восемнадцать девятнадцать двадцать тридцать сорок пятьдесят".split(),
               "0 1 1 2 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 30 40 50".split()))


def norm(t):
    t = t.lower().replace("ё", "е")
    t = re.sub(r"(?<=\w)[-'’](?=\w)", " ", t)
    t = re.sub(r"[^\w\s]", " ", t)
    return [NUM.get(w, w) for w in t.split() if w not in FILL]


def ed(a, b):
    p = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        c = [i]
        for j, y in enumerate(b, 1):
            c.append(min(p[j] + 1, c[j - 1] + 1, p[j - 1] + (x != y)))
        p = c
    return p[-1]


def squash(t):
    return re.sub(r"[\s\-.]", "", t.lower())


def load(d):
    refs = json.load(open(f"{d}/refs.json"))
    clips = {c["id"]: c for c in json.load(open(f"{d}/clips/clips.json"))}
    return refs, clips


def score(refs, hyps, ids=None):
    """-> (WER, names hit rate, median sec) over ids (default: all clips)."""
    ids = ids or list(refs)
    E = N = kh = kt = 0
    secs = []
    for i in ids:
        hyp = hyps.get(i, {}).get("text", "")
        r = norm(refs[i]["text"])
        E += ed(r, norm(hyp))
        N += len(r)
        for k in refs[i]["keys"]:
            kt += 1
            kh += squash(k) in squash(hyp)
        s = hyps.get(i, {}).get("sec")
        if s and s > 0:
            secs.append(s)
    return E / N, (kh / kt if kt else 0), (statistics.median(secs) if secs else None)


def runs(d, clips):
    out = {"wispr-raw-asr": {i: {"text": c["wispr_asr"], "sec": (c["e2eLatency"] or 0) / 1000} for i, c in clips.items()},
           "wispr-final": {i: {"text": c["wispr_formatted"], "sec": (c["e2eLatency"] or 0) / 1000} for i, c in clips.items()}}
    for f in sorted(glob.glob(f"{d}/runs/*.json")):
        out[os.path.basename(f)[:-5]] = json.load(open(f))
    return out


def main(d):
    refs, clips = load(d)
    ru = [i for i in refs if clips[i]["lang"] != "en"]
    rows = []
    for n, h in runs(d, clips).items():
        w, k, s = score(refs, h)
        rows.append((w, n, score(refs, h, ru)[0], k, s))
    print(f"{'run':50} {'WER all':>8} {'WER ru':>7} {'names':>6} {'med s':>6}")
    for w, n, wr, k, s in sorted(rows):
        print(f"{n:50} {w:8.1%} {wr:7.1%} {k:6.0%} {s if s is None else round(s, 2)!s:>6}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SUSU_TESTSET", os.path.expanduser("~/Projects/susu/research-private/stt")))
