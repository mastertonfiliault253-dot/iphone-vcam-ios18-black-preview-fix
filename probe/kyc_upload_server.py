# KYC 采集链路测试的托管服务：GET 提供 probe 页面，POST /upload?name=… 保存设备回传的媒体文件。
# 用法：python probe/kyc_upload_server.py [port=8077]
# 注意：Safari 只在安全上下文暴露 getUserMedia，设备端需经 `ssh -R <port>:<pc-ip>:<port> root@<device>`
# 后用 http://127.0.0.1:<port>/kyc-camera-test.html 打开（局域网 http:// 直开时 API 为 undefined）。
import http.server
import socketserver
import sys
from pathlib import Path
from urllib.parse import urlparse, parse_qs

import datetime

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8077
ROOT = Path(__file__).resolve().parent
UPLOADS = ROOT / "uploads"
UPLOADS.mkdir(exist_ok=True)
REPORTS = UPLOADS / "reports"
REPORTS.mkdir(parents=True, exist_ok=True)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def _read_body(self):
        size = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(size)

    def _save(self, path, data):
        path.write_bytes(data)
        print(f"saved {path} ({len(data)} bytes)", flush=True)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(path.name.encode())

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/report":
            # KYC 流程测试台的结构化报告：按时间戳存档，避免互相覆盖。
            data = self._read_body()
            name = datetime.datetime.now().strftime("report_%Y%m%d_%H%M%S.json")
            self._save(REPORTS / name, data)
            return
        if parsed.path != "/upload":
            self.send_error(404)
            return
        name = parse_qs(parsed.query).get("name", ["upload.bin"])[0]
        name = "".join(c for c in name if c.isalnum() or c in "._-")
        self._save(UPLOADS / name, self._read_body())


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("0.0.0.0", PORT), Handler) as httpd:
    print(f"serving on :{PORT}, uploads -> {UPLOADS}", flush=True)
    httpd.serve_forever()
