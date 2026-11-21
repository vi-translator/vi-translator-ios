"""A stand-in for a VI Translator TV app, for CI: it waits to be connected as the TV apps do
(GET /vit-tv and POST /vit-tv/pair on port 8792, with the X-VIT header), then reads the phone's
TV page (/tv.json, long-polled) as a TV would, and reports what it showed.

    python3 ci/fake_tv.py --code 123456 --timeout 240 --want-lines 1

Exit code 0: connected, the phone's page answered, and (with --want-lines) lines came through.
"""
import argparse
import json
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8792)
ap.add_argument("--code", default="123456")
ap.add_argument("--timeout", type=float, default=240)
ap.add_argument("--want-lines", type=int, default=0)
ap.add_argument("--out", default="fake-tv.json")
args = ap.parse_args()

paired = {}
done = threading.Event()


class Tv(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        print("fake TV:", fmt % a, flush=True)

    def answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/vit-tv") and self.headers.get("X-VIT"):
            self.answer(200, {"app": "vi-translator-tv", "id": "ci-tv", "name": "CI TV", "version": "ci"})
        else:
            self.answer(404, {})

    def do_POST(self):
        if not (self.path == "/vit-tv/pair" and self.headers.get("X-VIT")):
            return self.answer(404, {})
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        print("fake TV: pair request", {k: v for k, v in body.items() if k != "token"}, flush=True)
        if body.get("code") != args.code:
            return self.answer(403, {"error": "wrong code"})
        paired.update(body)
        self.answer(200, {"id": "ci-tv", "name": "CI TV"})
        done.set()


server = ThreadingHTTPServer(("0.0.0.0", args.port), Tv)
threading.Thread(target=server.serve_forever, daemon=True).start()
print("fake TV: waiting on port", args.port, flush=True)

if not done.wait(args.timeout):
    print("fake TV: nobody connected", flush=True)
    sys.exit(1)

pc, token = paired.get("pc"), paired.get("token")
print("fake TV: connected to", paired.get("pc_name"), "at", pc, flush=True)
# the phone's address, as the TV gets it, may be its LAN address; this TV runs on the same Mac
hosts = [pc]
if pc and ":" in pc:
    hosts.append("127.0.0.1:" + pc.rsplit(":", 1)[1])

result = {"paired": True, "pc": pc, "states": []}
end = time.time() + args.timeout
version = ""
ok = False
lines_seen = 0
while time.time() < end:
    for h in hosts:
        try:
            req = urllib.request.Request("http://%s/tv.json?t=%s&h=%s" % (h, token, version), headers={"X-VIT": "1"})
            with urllib.request.urlopen(req, timeout=30) as r:
                state = json.loads(r.read().decode() or "{}")
                version = str(r.headers.get("X-State") or state.get("version") or state.get("h") or "")
                ok = True
                result["states"].append(state)
                text = json.dumps(state, ensure_ascii=False)
                print("fake TV: page state", text[:400], flush=True)
                shown = state.get("shown") or {}
                items = list(shown.values()) if isinstance(shown, dict) else list(shown)
                lines_seen = max(lines_seen, len([x for x in items if x]))
                break
        except Exception as e:  # noqa: BLE001
            print("fake TV:", h, e, flush=True)
    if ok and lines_seen >= args.want_lines:
        break
    time.sleep(1)

result["ok"] = ok
result["lines"] = lines_seen
json.dump(result, open(args.out, "w"), ensure_ascii=False, indent=1)
print("fake TV: page answered" if ok else "fake TV: the page never answered", "| lines shown:", lines_seen, flush=True)
sys.exit(0 if ok and lines_seen >= args.want_lines else 1)
