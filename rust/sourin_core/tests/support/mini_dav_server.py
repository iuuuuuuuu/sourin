#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════════════
#  WebDAV 仪器（小写 `d:` 前缀）—— t77 的**阳性对照**
# ═══════════════════════════════════════════════════════════════════════
#
# # 为什么需要它
#
# `tests/t77_dav_prefix.rs` 要证明的是「命名空间前缀无关」：
# 服务器发 `<D:response>`（大写，wsgidav 的实测行为）时解析器也要认。
# 但**否定读数只有在仪器被证明是灵敏的时���才是证据** ——
# 所以必须再拿一台发**小写 `<d:response>`** 的服务器走一遍**同一条代码路径**：
# 它必须也能列出来，才能说明「两种拼写都行」，而不是「换了个服务器就好了」。
#
# # 之前它住在 `.probe/t91_dav_server.py`（gitignored，从未入库）
#
# 后果：`cargo test --test t77_dav_prefix -- --ignored` 对**任何人**都必然红在
# 「positive-control instrument missing」—— 仪器根本没进仓库。
# 本文件是该仪器的**入库版本**，放在 `tests/support/` 下。
#
# # 它刻意与 wsgidav 不同的两点（这正是对照的意义）
#
#   ① 前缀小写 `<d:`（wsgidav 发的是大写 `<D:`）
#   ② ETag 用 `&quot;…&quot;` 转义（坚果云的实测行为）
#
# 用法：
#   python tests/support/mini_dav_server.py --root DIR --port N \
#          [--log FILE] [--user u] [--password p]
import argparse
import base64
import json
import os
import sys
import threading
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = ''
LOG = None
USER = 'u'
PASSWORD = 'p'


def _log(method, path, status):
    if not LOG:
        return
    with open(LOG, 'a', encoding='utf-8') as f:
        f.write(json.dumps({'method': method, 'path': path,
                            'status': int(status)}, ensure_ascii=False) + '\n')


def _esc(s):
    return (s.replace('&', '&amp;').replace('<', '&lt;')
             .replace('>', '&gt;').replace('"', '&quot;'))


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'mini-dav/1.0'

    def log_message(self, *a):  # 静默（否则每次请求都往 stderr 刷）
        pass

    # ── 认证 ──
    def _authed(self):
        h = self.headers.get('Authorization', '')
        if not h.lower().startswith('basic '):
            return False
        try:
            raw = base64.b64decode(h[6:].strip()).decode('utf-8')
        except Exception:
            return False
        return raw == f'{USER}:{PASSWORD}'

    def _deny(self):
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="dav"')
        self.send_header('Content-Length', '0')
        self.end_headers()
        _log(self.command, self.path, 401)

    def _send(self, code, body=b'', ctype='text/plain'):
        if isinstance(body, str):
            body = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)
        _log(self.command, self.path, code)

    def _disk(self):
        rel = self.path.split('?')[0].strip('/')
        parts = [p for p in rel.split('/') if p and p not in ('.', '..')]
        return os.path.join(ROOT, *parts), '/'.join(parts)

    # ── 动词 ──
    def do_PROPFIND(self):
        if not self._authed():
            return self._deny()
        disk, _rel = self._disk()
        if not os.path.exists(disk):
            return self._send(404, 'no such resource')
        depth = (self.headers.get('Depth') or '0').strip()

        # 单个**文件**资源（Depth: 0 打在一个文件上）—— 真实服务器也这么回。
        # 少了这一支，`etag()` 恒为 None ⇒ 条件写退化成无条件写。
        if not os.path.isdir(disk):
            size = os.path.getsize(disk)
            body = ('<?xml version="1.0" encoding="utf-8"?>'
                    '<d:multistatus xmlns:d="DAV:">'
                    '<d:response><d:href>/</d:href><d:propstat><d:prop>'
                    f'<d:getcontentlength>{size}</d:getcontentlength>'
                    f'<d:getlastmodified>{formatdate(usegmt=True)}</d:getlastmodified>'
                    f'<d:getetag>&quot;{size}&quot;</d:getetag>'
                    '</d:prop></d:propstat></d:response></d:multistatus>')
            return self._send(207, body, 'application/xml')

        out = ['<?xml version="1.0" encoding="utf-8"?>',
               '<d:multistatus xmlns:d="DAV:">',
               '<d:response><d:href>/</d:href><d:propstat><d:prop>'
               '<d:resourcetype><d:collection/></d:resourcetype>'
               '</d:prop></d:propstat></d:response>']
        for name in sorted(os.listdir(disk)):
            if depth == '0':
                break
            full = os.path.join(disk, name)
            if os.path.isdir(full):
                out.append(
                    f'<d:response><d:href>/{_esc(name)}/</d:href><d:propstat><d:prop>'
                    '<d:resourcetype><d:collection/></d:resourcetype>'
                    '</d:prop></d:propstat></d:response>')
            else:
                size = os.path.getsize(full)
                # ★ ETag 用 &quot; 转义 —— 与坚果云实测一致
                out.append(
                    f'<d:response><d:href>/{_esc(name)}</d:href><d:propstat><d:prop>'
                    f'<d:getcontentlength>{size}</d:getcontentlength>'
                    f'<d:getlastmodified>{formatdate(usegmt=True)}</d:getlastmodified>'
                    f'<d:getetag>&quot;{size}&quot;</d:getetag>'
                    '</d:prop></d:propstat></d:response>')
        out.append('</d:multistatus>')
        self._send(207, ''.join(out), 'application/xml')

    def do_MKCOL(self):
        if not self._authed():
            return self._deny()
        disk, _rel = self._disk()
        if os.path.exists(disk):
            return self._send(405, 'already exists')
        if not os.path.isdir(os.path.dirname(disk)):
            return self._send(409, 'parent missing')
        os.mkdir(disk)
        self._send(201)

    def do_PUT(self):
        if not self._authed():
            return self._deny()
        disk, _rel = self._disk()
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n) if n else b''
        os.makedirs(os.path.dirname(disk), exist_ok=True)
        with open(disk, 'wb') as f:
            f.write(body)
        self._send(201)

    def do_GET(self):
        if not self._authed():
            return self._deny()
        disk, _rel = self._disk()
        if not os.path.isfile(disk):
            return self._send(404, 'not found')
        with open(disk, 'rb') as f:
            self._send(200, f.read(), 'application/octet-stream')

    def do_DELETE(self):
        if not self._authed():
            return self._deny()
        disk, _rel = self._disk()
        if not os.path.isfile(disk):
            return self._send(404, 'not found')
        os.remove(disk)
        self._send(204)

    def do_HEAD(self):
        if not self._authed():
            return self._deny()
        disk, _rel = self._disk()
        self._send(200 if os.path.exists(disk) else 404)


def main():
    global ROOT, LOG, USER, PASSWORD
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--port', type=int, required=True)
    ap.add_argument('--log', default=None)
    ap.add_argument('--user', default='u')
    ap.add_argument('--password', default='p')
    a = ap.parse_args()
    ROOT = os.path.abspath(a.root)
    LOG = a.log
    USER, PASSWORD = a.user, a.password
    os.makedirs(ROOT, exist_ok=True)
    srv = ThreadingHTTPServer(('127.0.0.1', a.port), Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    sys.stderr.write(f'mini_dav_server listening on 127.0.0.1:{a.port} root={ROOT}\n')
    sys.stderr.flush()
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()