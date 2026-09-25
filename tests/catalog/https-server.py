#!/usr/bin/env python3
"""catalog 测试用的本地 HTTPS 服务：按 Host 头从 /srv/www/<host>/ 提供文件。

容器里把 raw.githubusercontent.com / github.com / downloads.ctest.example 等指到 127.0.0.1，
证书由测试 CA 签发并加入系统信任库，这样被测脚本用的就是真实的固定 URL。
"""
import http.server
import os
import ssl

ROOT = "/srv/www"


class Handler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        host = self.headers.get("Host", "").split(":")[0]
        parts = [p for p in path.split("?", 1)[0].split("/") if p not in ("", ".", "..")]
        return os.path.join(ROOT, host, *parts)

    def log_message(self, *args):
        pass


httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 443), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/etc/ctest/server.crt", "/etc/ctest/server.key")
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
