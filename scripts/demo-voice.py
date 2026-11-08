#!/usr/bin/env python3
"""Records the welcome demo's voice with Sarvam's text-to-speech (Bulbul) and writes one m4a per line to
EditMax/Resources/Demo/Voice/demo-<voice>.m4a, where WelcomeTour's DemoVoice finds them.

The lines come from DemoBeat.script in EditMax/App/WelcomeTour.swift, so the voice never drifts from the demo.

The API key is read from $SARVAM_API_KEY or ~/.editmax-sarvam/api-key and never printed.

    python3 -I scripts/demo-voice.py --speaker anushka --sample /tmp/voices   # the first line only, to choose a voice
    python3 -I scripts/demo-voice.py --speaker anushka                        # every line, into the app's resources
"""
import argparse, base64, json, os, pathlib, re, subprocess, sys, tempfile, urllib.request, urllib.error

ROOT = pathlib.Path(__file__).resolve().parent.parent
SWIFT = ROOT / "EditMax/App/WelcomeTour.swift"
OUT = ROOT / "EditMax/Resources/Demo/Voice"
URL = "https://api.sarvam.ai/text-to-speech"


def lines():
    text = SWIFT.read_text()
    found = re.findall(r'\.init\(voice: "([a-z]+)", caption: "[^"]*", line: "((?:[^"\\]|\\.)*)"', text)
    if not found:
        sys.exit("no lines found in DemoBeat.script")
    return found


def key():
    k = os.environ.get("SARVAM_API_KEY", "").strip()
    if not k:
        p = pathlib.Path.home() / ".editmax-sarvam/api-key"
        if p.exists():
            k = p.read_text().strip()
    if not k:
        sys.exit("put the Sarvam API key in ~/.editmax-sarvam/api-key (or $SARVAM_API_KEY)")
    return k


def speak(text, args, api_key):
    body = {"text": text, "target_language_code": args.language, "speaker": args.speaker, "model": args.model,
            "pace": args.pace, "speech_sample_rate": 24000}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), method="POST",
                                 headers={"api-subscription-key": api_key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"Sarvam said {e.code}: {e.read().decode(errors='replace')[:400]}")
    audios = data.get("audios") or []
    if not audios:
        sys.exit(f"no audio in the answer: {str(data)[:300]}")
    return b"".join(base64.b64decode(a) for a in audios)


def to_m4a(wav, out):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        f.write(wav)
        tmp = f.name
    try:
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "96000", tmp, str(out)], check=True)
    finally:
        os.unlink(tmp)


def main():
    a = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument("--speaker", required=True, help="a Bulbul speaker, e.g. anushka, vidya, manisha, arya, abhilash, karun, hitesh")
    a.add_argument("--model", default="bulbul:v2")
    a.add_argument("--language", default="en-IN")
    a.add_argument("--pace", type=float, default=1.0)
    a.add_argument("--sample", metavar="DIR", help="record only the first line, into DIR, to hear the voice")
    args = a.parse_args()
    api_key = key()
    todo = lines()[:1] if args.sample else lines()
    out_dir = pathlib.Path(args.sample) if args.sample else OUT
    out_dir.mkdir(parents=True, exist_ok=True)
    for voice, text in todo:
        text = text.replace('\\"', '"')
        name = f"sample-{args.speaker}.m4a" if args.sample else f"demo-{voice}.m4a"
        to_m4a(speak(text, args, api_key), out_dir / name)
        print(f"{name}: {text}")


if __name__ == "__main__":
    main()
