"""Loopback-only preview of the actual NUI with explicitly synthetic fixtures.

No game commands, credentials, player saves or repository metadata are served.
"""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]

class Preview(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        path = urlsplit(self.path).path
        allowed = path.startswith(("/docs/store/", "/adapter/nui/")) or path in (
            "/tools/preview.html", "/tools/ui-fixture.js")
        target = (ROOT / path.lstrip("/")).resolve()
        if not allowed or not target.is_relative_to(ROOT) or not target.is_file():
            self.send_error(404)
            return
        if path == "/adapter/nui/index.html":
            body = target.read_text(encoding="utf-8").replace(
                '<script src="app.js"></script>',
                '<script src="/tools/ui-fixture.js?v=release2"></script><script src="app.js?v=release2"></script>')
            data = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        super().do_GET()

if __name__ == "__main__":
    print("Underworld preview: http://127.0.0.1:8766/docs/store/index.html", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8766), Preview).serve_forever()
