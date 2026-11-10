#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""stashapi local JSON API (loopback-only).

Endpoints:
    GET  /hello                 -> {"ok":true,"port":N}
    POST /execute  {"cmd","cwd","timeout"} -> {"out","err","code","cwd"}
    POST /interrupt             -> {"ok":true}   (kills the running command tree)

Stability rules:
    - binds 127.0.0.1 only; loopback peers only
    - each command = one fresh process (nothing to wedge, nothing to leak)
    - every response has Content-Length + Connection: close
    - output capped; stderr captured to the debug log
"""
import http.server
import json
import os
import re
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse

IS_WIN = os.name == 'nt'
PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
PORT_FILE = os.path.join(PLUGIN_DIR, '.server_port')
LOG_FILE = os.path.join(PLUGIN_DIR, '.server_debug.log')
PID_FILE = os.path.join(PLUGIN_DIR, '.cmd_pid')
BASE_PORT = 17653

MAX_OUT = 512 * 1024
MAX_ERR = 64 * 1024


def _log(msg):
    try:
        with open(LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(time.strftime('%H:%M:%S ') + msg + '\n')
    except Exception:
        pass


PID_LOCK = threading.Lock()
_EXEC_JOB = None  # shared named exec job handle (Windows), created lazily


def _kill_tree(pid):
    try:
        if IS_WIN:
            subprocess.run(['taskkill', '/F', '/T', '/PID', str(pid)],
                           capture_output=True, timeout=10)
        else:
            import signal
            os.killpg(os.getpgid(pid), signal.SIGKILL)
    except Exception as ex:
        _log('kill_tree: %r' % ex)


EXEC_RAM_MB = 1536  # exec'd children live in a RAM box: a runaway exe
                    # must never starve stash (Go dies on failed commit -> 503)
EXEC_JOB_NAME = 'stashapi_exec_ram'  # ONE named job shared by every exec tree
                                     # (all ops + daemon): global ceiling below
try:
    EXEC_JOB_TOTAL_MB = max(512, min(32768,
                                     int(os.environ.get('STASHAPI_EXEC_JOB_MB') or 2560)))
except (TypeError, ValueError):
    EXEC_JOB_TOTAL_MB = 2560
# note: per-op custom ram re-applies limits on the SHARED job (last writer wins)


def _win_job_create(limit_mb, total_mb=0):
    """Job object: per-process memory ceiling + kill-on-close. The whole
    exec'd tree (cmd -> exe -> grandchildren) gets its own RAM box."""
    try:
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.windll.kernel32

        class _IO(ctypes.Structure):
            _fields_ = [(n, ctypes.c_ulonglong) for n in (
                'ReadOperationCount', 'WriteOperationCount', 'OtherOperationCount',
                'ReadTransferCount', 'WriteTransferCount', 'OtherTransferCount')]

        class _Basic(ctypes.Structure):
            _fields_ = [
                ('PerProcessUserTimeLimit', ctypes.c_int64),
                ('PerJobUserTimeLimit', ctypes.c_int64),
                ('LimitFlags', wintypes.DWORD),
                ('MinimumWorkingSetSize', ctypes.c_size_t),
                ('MaximumWorkingSetSize', ctypes.c_size_t),
                ('ActiveProcessLimit', wintypes.DWORD),
                ('Affinity', ctypes.c_size_t),
                ('PriorityClass', wintypes.DWORD),
                ('SchedulingClass', wintypes.DWORD)]

        class _Ext(ctypes.Structure):
            _fields_ = [('BasicLimitInformation', _Basic), ('IoInfo', _IO),
                        ('ProcessMemoryLimit', ctypes.c_size_t),
                        ('JobMemoryLimit', ctypes.c_size_t),
                        ('PeakProcessMemoryUsed', ctypes.c_size_t),
                        ('PeakJobMemoryUsed', ctypes.c_size_t)]

        job = k32.CreateJobObjectW(None, EXEC_JOB_NAME)
        if not job:
            return None
        info = _Ext()
        # PROCESS_MEMORY | JOB_MEMORY (if set) | KILL_ON_JOB_CLOSE
        info.BasicLimitInformation.LimitFlags = 0x100 | 0x2000 | (0x200 if total_mb else 0)
        info.ProcessMemoryLimit = limit_mb * 1024 * 1024
        if total_mb:
            info.JobMemoryLimit = total_mb * 1024 * 1024
        if not k32.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info)):
            k32.CloseHandle(job)
            return None
        return job
    except Exception:
        return None


def _parse_ram_mb(raw):
    try:
        ram = int(raw or 0)
    except (TypeError, ValueError):
        ram = 0
    if ram <= 0:
        ram = EXEC_RAM_MB
    return max(128, min(16384, ram))


def _linux_rlimit_fn(limit_mb):
    def _fn():
        try:
            import resource
            b = limit_mb * 1024 * 1024
            resource.setrlimit(resource.RLIMIT_AS, (b, b))
        except Exception:
            pass
    return _fn


def _run_exec(cmd, cwd, timeout, ram_mb=0):
    if not cmd:
        return {'out': '', 'err': '', 'code': 0, 'cwd': cwd}
    if IS_WIN:
        shell_cmd = 'chcp 65001 >nul 2>&1 & cd /d "%s" && %s' % (cwd.replace('"', ''), cmd)
    else:
        shell_cmd = 'cd "%s" && %s' % (cwd.replace('"', ''), cmd)
    if timeout <= 0:
        timeout = 600.0
    if ram_mb <= 0:
        ram_mb = EXEC_RAM_MB
    ram_mb = max(128, min(16384, ram_mb))
    job = None
    popen_kw = {'stdout': subprocess.PIPE, 'stderr': subprocess.PIPE,
                'stdin': subprocess.DEVNULL, 'cwd': cwd,
                'start_new_session': not IS_WIN}
    if IS_WIN:
        global _EXEC_JOB
        if _EXEC_JOB is None:
            _EXEC_JOB = _win_job_create(ram_mb, EXEC_JOB_TOTAL_MB)
        job = _EXEC_JOB  # shared: never closed while the daemon lives
    else:
        # Linux: per-process RLIMIT_AS only; a global ceiling needs cgroups
        job = None
        popen_kw['preexec_fn'] = _linux_rlimit_fn(ram_mb)
    try:
        proc = subprocess.Popen(shell_cmd, shell=True, **popen_kw)
    except OSError as ex:
        return {'out': '', 'err': str(ex), 'code': 1, 'cwd': cwd}
    if job:
        try:
            import ctypes
            ctypes.windll.kernel32.AssignProcessToJobObject(job, int(proc._handle))
        except Exception:
            job = None

    with PID_LOCK:
        try:
            with open(PID_FILE, 'w') as f:
                f.write(str(proc.pid))
        except OSError:
            pass

    # bounded streaming read (see the rationale in the project history):
    # RAM never exceeds the caps even for multi-hundred-MB outputs
    out_buf, err_buf = [], []
    counters = [[0], [0]]

    def _pump(pipe, buf, cap, counter):
        while True:
            chunk = pipe.readline()
            if not chunk:
                return
            counter[0] += len(chunk)
            if counter[0] <= cap:
                buf.append(chunk)

    t_out = threading.Thread(target=_pump, args=(proc.stdout, out_buf, MAX_OUT, counters[0]), daemon=True)
    t_err = threading.Thread(target=_pump, args=(proc.stderr, err_buf, MAX_ERR, counters[1]), daemon=True)
    t_out.start()
    t_err.start()
    deadline = time.time() + timeout
    timed_out = False
    while t_out.is_alive() or t_err.is_alive():
        t_out.join(0.5)
        t_err.join(0.5)
        if time.time() > deadline:
            timed_out = True
            _kill_tree(proc.pid)
            break
    proc.wait(timeout=30)

    with PID_LOCK:
        try:
            cur = open(PID_FILE).read().strip()
            if cur == str(proc.pid):
                os.remove(PID_FILE)
        except Exception:
            pass

    out_text = b''.join(out_buf).decode('utf-8', 'replace')
    err_text = b''.join(err_buf).decode('utf-8', 'replace')
    if len(out_text) > MAX_OUT:
        out_text = out_text[:MAX_OUT] + '\n[... вывод обрезан (%d байт)]' % counters[0][0]
    if len(err_text) > MAX_ERR:
        err_text = err_text[:MAX_ERR] + '\n[... stderr обрезан]'
    res = {'out': out_text, 'err': err_text,
           'code': proc.returncode or 0, 'cwd': cwd}
    if timed_out:
        res['err'] += '\n[прервано по таймауту %gs]' % timeout
    return res


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    timeout = 300  # per-request socket timeout: a stuck client frees its thread

    def log_message(self, format, *args):
        pass

    def _origin_ok(self):
        """CSRF shield: browser requests always carry Origin/Referer from the
        Stash page (localhost). A foreign site's page would carry ITS origin
        here (DNS-rebinding keeps the host the same but not the Origin header).
        Non-browser clients (curl/python) send none and are allowed."""
        for h in ('Origin', 'Referer'):
            val = self.headers.get(h)
            if not val:
                continue
            try:
                host = urllib.parse.urlsplit(val).hostname or ''
            except ValueError:
                return False
            if host not in ('localhost', '127.0.0.1', '::1'):
                return False
        return True

    def _headers(self, code, ctype, body):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Length', str(len(body)))
        # ALWAYS close: keep-alive sockets make browser/tooling clients hang
        self.send_header('Connection', 'close')
        self.close_connection = True
        self.end_headers()

    def _plain(self, code, text, ctype='application/json'):
        body = text.encode('utf-8', 'replace')
        self._headers(code, ctype, body)
        self.wfile.write(body)

    def _loopback(self):
        try:
            ip = self.connection.getpeername()[0]
        except Exception:
            return False
        return ip == '127.0.0.1' or ip == '::1'

    def do_GET(self):
        if not self._loopback():
            self._plain(403, '{"err":"loopback only"}')
            return
        if not self._origin_ok():
            _log('403 foreign origin: %s' % (self.headers.get('Origin') or
                                             self.headers.get('Referer') or '-'))
            self._plain(403, '{"err":"foreign origin"}')
            return
        if self.path == '/hello':
            self._plain(200, json.dumps({'ok': True, 'port': SERVER_PORT, 'v2': True}))
            return

        if self.path.startswith('/download'):
            self._serve_download()
            return
        self._plain(404, '{"err":"not found"}')

    def _serve_download(self):
        """Stream a file to the browser: no buffering, no base64, no stash.
        ?path=<file>&name=<save-as>&inline=1 (inline=1 -> shown, not saved)."""
        try:
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            path = q.get('path', [''])[0]
            name = os.path.basename(q.get('name', [''])[0]) or os.path.basename(path)
            inline = q.get('inline', [''])[0] == '1'
            if not path or not os.path.isfile(path):
                self._plain(404, '{"err":"not a file"}')
                return
            import mimetypes
            size = os.path.getsize(path)
            ctype = mimetypes.guess_type(path)[0] or 'application/octet-stream'
            disp = 'inline' if inline else 'attachment'
            self.send_response(200)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(size))
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Content-Disposition',
                             "%s; filename*=UTF-8''%s" % (disp, urllib.parse.quote(name)))
            self.send_header('Connection', 'close')
            self.close_connection = True
            self.end_headers()
            with open(path, 'rb') as f:
                while True:
                    chunk = f.read(1024 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            _log('download ok: %s (%d bytes)' % (path, size))
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
            _log('download aborted by client')
        except Exception as ex:
            _log('download failed: %r' % ex)
            try:
                self._plain(500, json.dumps({'ok': False, 'err': str(ex)}))
            except Exception:
                pass

    def do_POST(self):
        if not self._loopback():
            self._plain(403, '{"err":"loopback only"}')
            return
        if not self._origin_ok():
            _log('403 foreign origin: %s' % (self.headers.get('Origin') or
                                             self.headers.get('Referer') or '-'))
            self._plain(403, '{"err":"foreign origin"}')
            return

        # streaming upload: body goes to disk in chunks, never buffered whole
        if self.path.startswith('/upload'):
            try:
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                dirp = q.get('dir', [''])[0]
                name = os.path.basename(q.get('name', [''])[0])
                if not dirp or not name or not os.path.isdir(dirp):
                    self._plain(400, '{"err":"bad dir/name"}')
                    return
                try:
                    length = int(self.headers.get('Content-Length') or 0)
                except ValueError:
                    length = 0
                if 'Content-Length' not in self.headers:
                    # chunked bodies are not supported: fail fast instead of
                    # writing an empty file while the client keeps streaming
                    self._plain(411, '{"err":"Content-Length required"}')
                    return
                target = os.path.join(dirp, name)
                n = 0
                with open(target, 'wb') as fo:
                    remaining = length
                    while remaining > 0:
                        chunk = self.rfile.read(min(1024 * 1024, remaining))
                        if not chunk:
                            break
                        fo.write(chunk)
                        n += len(chunk)
                        remaining -= len(chunk)
                self._plain(200, json.dumps({'ok': True, 'path': target, 'size': n}))
            except Exception as ex:
                _log('upload failed: %r' % ex)
                self._plain(500, json.dumps({'ok': False, 'err': str(ex)}))
            return

        try:
            length = int(self.headers.get('Content-Length', 0))
            data = json.loads(self.rfile.read(length) or b'{}')
            if not isinstance(data, dict):
                data = {}
        except Exception:
            data = {}

        if self.path == '/interrupt':
            try:
                pid = int(open(PID_FILE).read().strip())
                _kill_tree(pid)
                os.remove(PID_FILE)
                self._plain(200, json.dumps({'ok': True}))
            except Exception:
                self._plain(200, json.dumps({'ok': False}))
            return

        if self.path == '/execute':
            cmd = str(data.get('cmd', ''))
            cwd = str(data.get('cwd', '') or os.getcwd())
            if not os.path.isdir(cwd):
                cwd = os.getcwd()
            try:
                timeout = float(data.get('timeout') or 0)
            except (TypeError, ValueError):
                timeout = 0
            try:
                res = _run_exec(cmd, cwd, timeout, _parse_ram_mb(data.get('ram')))
            except Exception as ex:
                _log('execute failed: %r' % ex)
                res = {'out': '', 'err': str(ex), 'code': 1, 'cwd': cwd}
            self._plain(200, json.dumps(res, ensure_ascii=False))
            return

        self._plain(404, '{"err":"not found"}')


SERVER_PORT = 0


def main():
    global SERVER_PORT
    socketserver.ThreadingTCPServer.allow_reuse_addr = True
    socketserver.ThreadingTCPServer.daemon_threads = True

    httpd = None
    for p in [BASE_PORT] + list(range(BASE_PORT + 1, BASE_PORT + 50)):
        try:
            httpd = socketserver.ThreadingTCPServer(('127.0.0.1', p), Handler)
            break
        except OSError:
            continue
    if httpd is None:
        sys.exit(0)
    SERVER_PORT = httpd.server_address[1]

    # advertise port only after a successful bind
    try:
        with open(PORT_FILE, 'w') as f:
            f.write(str(SERVER_PORT))
    except OSError:
        pass
    # pid file so act_reset can restart the daemon when its code changes
    try:
        with open(os.path.join(PLUGIN_DIR, '.server_pid'), 'w') as f:
            f.write(str(os.getpid()))
    except OSError:
        pass

    _log('daemon up on %d' % SERVER_PORT)
    try:
        httpd.serve_forever()
    except Exception as ex:
        _log('daemon crashed: %r' % ex)


if __name__ == '__main__':
    try:
        sys.stderr = open(LOG_FILE, 'a', encoding='utf-8')
    except Exception:
        pass
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception:
        import traceback
        _log('server crashed: %s' % traceback.format_exc())
