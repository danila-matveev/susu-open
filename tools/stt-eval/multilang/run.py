# Transcribe the multilang set with Groq Whisper turbo, without and with the term hint.
# usage: GROQ_API_KEY=... python3 -I run.py DIR   (DIR from gen.sh; writes DIR/results.json)
import glob, json, os, sys, time, urllib.request, uuid

D = sys.argv[1]
K = os.environ["GROQ_API_KEY"]
HINT = "Claude Code, Notion, TickTick, Telegram, ChatGPT, Wildberries."  # terms only, no wrapper words (spec 3.3)
MODEL = "whisper-large-v3-turbo"


def transcribe(path, prompt):
    b = uuid.uuid4().hex
    fields = {"model": MODEL, "response_format": "verbose_json", "temperature": "0"}
    if prompt:
        fields["prompt"] = prompt
    body = b"".join(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields.items())
    body += f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="{os.path.basename(path)}"\r\nContent-Type: audio/wav\r\n\r\n'.encode()
    body += open(path, "rb").read() + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request("https://api.groq.com/openai/v1/audio/transcriptions", body,
                                 {"Authorization": f"Bearer {K}", "User-Agent": "susu-stt-eval/1", "Content-Type": f"multipart/form-data; boundary={b}"})
    return json.load(urllib.request.urlopen(req, timeout=30))


R = {}
for hint in (False, True):
    name = MODEL + ("+hint" if hint else "")
    R[name] = {}
    for f in sorted(glob.glob(f"{D}/*.wav")):
        t = time.time()
        try:
            j = transcribe(f, HINT if hint else None)
            R[name][os.path.basename(f)[:-4]] = {"text": j.get("text", "").strip(), "lang": j.get("language"), "sec": round(time.time() - t, 2)}
        except Exception as e:  # keep going; an empty text counts as a full error in score.py
            R[name][os.path.basename(f)[:-4]] = {"text": "", "err": str(e)[:200], "sec": round(time.time() - t, 2)}
        time.sleep(3.1)  # Groq free tier: 20 requests per minute
json.dump(R, open(f"{D}/results.json", "w"), ensure_ascii=False, indent=1)
print(f"wrote {D}/results.json")
