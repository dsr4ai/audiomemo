#!/usr/bin/env python3
"""Local stand-in for the Osmi import API, for testing "Transcribe with Osmi" without the real backend.
  POST /imports           -> {import_id, secret, upload_url, claim_url, expires_at}
  PUT  /upload/<id>       -> stores the body in <out-dir>/<id>.<ext>, 200
  POST /imports requires "Authorization: Bearer <token>" (the real API no longer accepts anonymous imports); 401 without it.
Usage: python3 scripts/fake_osmi_server.py [port=18080] [out-dir=./fake-osmi-uploads] [bytes-per-second (throttle, 0 = off)]
Then:  open -n AudioMemo.app --args -osmiBaseURL http://127.0.0.1:18080 -osmiNoOpen YES ..."""
import json, os, secrets, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
OUT = sys.argv[2] if len(sys.argv) > 2 else "fake-osmi-uploads"
RATE = int(sys.argv[3]) if len(sys.argv) > 3 else 0
os.makedirs(OUT, exist_ok=True)
IMPORTS = {}

class H(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        if self.path != "/imports": return self._json(404, {"error": "not found"})
        auth = self.headers.get("Authorization", "")
        print("auth", "Bearer ***" if auth.startswith("Bearer ") and len(auth) > 7 else "none", flush=True)
        if not auth.startswith("Bearer ") or len(auth) <= 7:
            return self._json(401, {"code": 401, "msg": "Missing authorization header"})
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        for k in ("filename", "size", "content_type", "duration_s", "source", "app_version"):
            if k not in body: return self._json(400, {"error": f"missing {k}"})
        iid, sec = secrets.token_hex(6), secrets.token_urlsafe(12)
        IMPORTS[iid] = body
        base = f"http://127.0.0.1:{PORT}"
        print("import", iid, body, flush=True)
        self._json(200, {"import_id": iid, "secret": sec, "upload_url": f"{base}/upload/{iid}",
                         "claim_url": f"{base}/app/#import={iid}.{sec}",
                         "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3600))})

    def do_PUT(self):
        iid = self.path.rsplit("/", 1)[-1]
        if iid not in IMPORTS: return self._json(404, {"error": "unknown import"})
        n = int(self.headers.get("Content-Length", 0))
        ext = os.path.splitext(IMPORTS[iid]["filename"])[1]
        path = os.path.join(OUT, iid + ext)
        with open(path, "wb") as f:
            left = n
            while left > 0:
                chunk = self.rfile.read(min(65536, left)); f.write(chunk); left -= len(chunk)
                if RATE: time.sleep(len(chunk) / RATE)
        print("upload", iid, n, "bytes, content-type", self.headers.get("Content-Type"), "->", path, flush=True)
        self._json(200, {"ok": True})

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
