"""Stands in for tools/crash-inbox/worker.js in tests: checks a POSTed report like the worker
does and prints it instead of filing an issue.  python3 tests/crash/fake_inbox.py 8787"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Inbox(BaseHTTPRequestHandler):
    def do_POST(self):
        report = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        ok = report["title"].startswith("Crash report:") and report["body"].startswith(
            "### Ironbound crash report"
        )
        print("received", report["title"], len(report["body"]), "chars", "ok" if ok else "REJECTED")
        sys.stdout.flush()
        self.send_response(201 if ok else 400)
        self.end_headers()
        self.wfile.write(b'{"issue": 1}')


HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8787), Inbox).serve_forever()
