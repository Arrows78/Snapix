import hashlib, hmac, json, sys, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

ACCESS, SECRET, BUCKET, REGION = "AKTEST", "s3cr3t/KEY+test", "snapix-bucket", "us-east-1"
store = {}

def sha(b): return hashlib.sha256(b).hexdigest()
def h(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
def quote(s, slash=False): return urllib.parse.quote(s, safe="/" if slash else "")

def signature(method, path, query, headers, payload_hash, stamp):
    day = stamp[:8]
    canon_q = "&".join(f"{quote(k)}={quote(v)}" for k, v in sorted(query))
    names = sorted(headers)
    canon = "\n".join([method, path, canon_q, "".join(f"{n}:{headers[n].strip()}\n" for n in names), ";".join(names), payload_hash])
    scope = f"{day}/{REGION}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", stamp, scope, sha(canon.encode())])
    k = h(h(h(h(("AWS4" + SECRET).encode(), day), REGION), "s3"), "aws4_request")
    return hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()

class S3(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body=b""):
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def handle_any(self):
        u = urllib.parse.urlsplit(self.path)
        raw_path = u.path
        query = urllib.parse.parse_qsl(u.query, keep_blank_values=True)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        q = dict(query)
        if "X-Amz-Signature" in q:  # presigned
            cred = q["X-Amz-Credential"]; stamp = q["X-Amz-Date"]
            signed = q["X-Amz-SignedHeaders"].split(";")
            hdrs = {n: self.headers.get(n, "") for n in signed}
            sig_q = [(k, v) for k, v in query if k != "X-Amz-Signature"]
            expect = signature(self.command, raw_path, sig_q, hdrs, "UNSIGNED-PAYLOAD", stamp)
            ok = cred.startswith(ACCESS + "/") and hmac.compare_digest(expect, q["X-Amz-Signature"])
        else:
            auth = self.headers.get("Authorization", "")
            try:
                parts = dict(p.strip().split("=", 1) for p in auth[len("AWS4-HMAC-SHA256 "):].split(","))
                signed = parts["SignedHeaders"].split(";")
                stamp = self.headers["x-amz-date"]
                hdrs = {n: self.headers.get(n, "") for n in signed}
                payload_hash = self.headers.get("x-amz-content-sha256", "")
                ok = (payload_hash == sha(body) and parts["Credential"].startswith(ACCESS + "/")
                      and hmac.compare_digest(signature(self.command, raw_path, query, hdrs, payload_hash, stamp), parts["Signature"]))
            except Exception:
                ok = False
        if not ok: return self.reply(403, b"SignatureDoesNotMatch")
        key = urllib.parse.unquote(raw_path)
        if not key.startswith("/" + BUCKET): return self.reply(404)
        if self.command == "PUT": store[key] = body; return self.reply(200)
        if self.command == "HEAD": return self.reply(200)
        if self.command == "GET": return self.reply(200, store[key]) if key in store else self.reply(404)
        self.reply(405)
    do_GET = do_PUT = do_HEAD = handle_any

class OCR(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        ok = self.path.endswith("/chat/completions") and self.headers.get("Authorization") == "Bearer test-key" and body.get("model") == "mock-vision"
        parts = body["messages"][0]["content"]
        has_image = any(p.get("type") == "image_url" and p["image_url"]["url"].startswith("data:image/png;base64,") for p in parts)
        text = "Hello from the mock server" if has_image else "OK"
        out = json.dumps({"choices": [{"message": {"content": text}}]}).encode() if ok else json.dumps({"error": {"message": "bad request"}}).encode()
        self.send_response(200 if ok else 401); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)

if __name__ == "__main__":
    s3 = HTTPServer(("127.0.0.1", 0), S3); ocr = HTTPServer(("127.0.0.1", 0), OCR)
    print(s3.server_port, ocr.server_port, flush=True)
    threading.Thread(target=ocr.serve_forever, daemon=True).start()
    s3.serve_forever()
