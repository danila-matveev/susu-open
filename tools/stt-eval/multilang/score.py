# Per-language scores for results.json from run.py, plus the gate for the default provider.
# usage: python3 -I score.py DIR [--gate RUN]   exit 1 if RUN misses: median error <= 10%, language 15/15, names >= 80%
import json, os, re, statistics, sys, unicodedata

T = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "texts.json")))
CJK = {"ja", "zh"}
LANG = {"en": "english", "ru": "russian", "es": "spanish", "pt": "portuguese", "de": "german", "fr": "french",
        "it": "italian", "pl": "polish", "uk": "ukrainian", "tr": "turkish", "id": "indonesian", "hi": "hindi",
        "ja": "japanese", "zh": "chinese", "ko": "korean"}


def norm(t, l):
    t = unicodedata.normalize("NFKC", t).lower().replace("ё", "е").replace("ʼ", "'").replace("’", "'")
    t = re.sub(r"[^\w\s']", " ", t)
    return list(t.replace(" ", "")) if l in CJK else t.split()  # CJK: character error rate


def ed(a, b):
    p = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        c = [i]
        for j, y in enumerate(b, 1):
            c.append(min(p[j] + 1, c[j - 1] + 1, p[j - 1] + (x != y)))
        p = c
    return p[-1]


def sq(s):
    return re.sub(r"[\s\-.'’]", "", s.lower())


def err(ref, hyp, l):
    r = norm(ref, l)
    return ed(r, norm(hyp, l)) / len(r)


def score(res):
    rows = {}
    for l, t in T.items():
        a, b = res.get(l + "a", {}), res.get(l + "b", {})
        ha, hb = a.get("text", ""), b.get("text", "")
        rows[l] = {"err_a": err(t["a"], ha, l), "err_mix": err(t["b"], hb, l),
                   "names": sum(n in sq(ha) for n in ("claudecode", "notion")) + ("ticktick" in sq(hb)),
                   "eng": "letmeknow" in sq(hb), "lang_ok": (a.get("lang") or "").lower() == LANG[l],
                   "lang": a.get("lang"), "sec": a.get("sec")}
    s = {"err_a": statistics.median(r["err_a"] for r in rows.values()),
         "err_mix": statistics.median(r["err_mix"] for r in rows.values()),
         "names": sum(r["names"] for r in rows.values()), "names_max": 3 * len(rows),
         "eng": sum(r["eng"] for r in rows.values()), "lang_ok": sum(r["lang_ok"] for r in rows.values()),
         "n": len(rows), "sec": statistics.median(r["sec"] for r in rows.values() if r["sec"])}
    return rows, s


def main():
    d = sys.argv[1]
    R = json.load(open(f"{d}/results.json"))
    gate = sys.argv[sys.argv.index("--gate") + 1] if "--gate" in sys.argv else None
    for name, res in R.items():
        rows, s = score(res)
        print(f"\n== {name}\nlang  err   err_mix names eng_kept detected    sec")
        for l, r in rows.items():
            print(f"{l:4} {r['err_a']:5.0%} {r['err_mix']:7.0%}  {r['names']}/3   {'yes' if r['eng'] else 'NO':3}     {str(r['lang']):11} {r['sec']}")
        print(f"MEDIAN err {s['err_a']:.0%}  err_mix {s['err_mix']:.0%}  names {s['names']}/{s['names_max']}  "
              f"eng kept {s['eng']}/{s['n']}  language {s['lang_ok']}/{s['n']}  sec {s['sec']}")
    if gate:
        _, s = score(R[gate])
        ok = s["err_a"] <= 0.10 and s["lang_ok"] == s["n"] and s["names"] / s["names_max"] >= 0.80
        print(f"\ngate {gate}: {'ok' if ok else 'FAIL'} (median error <= 10%, language {s['n']}/{s['n']}, names >= 80%)")
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
