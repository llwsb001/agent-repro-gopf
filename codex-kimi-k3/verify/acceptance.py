#!/usr/bin/env python3
"""Independent acceptance tests for the Zig port of gopf.

Checks the behaviors that matter, not the implementation:
  1. basic forwarding
  2. half-close propagation (backend replies only after seeing client EOF)
  3. weighted selection (100/0 -> all first; 1/1 -> both used)
  4. SIGHUP reload without restart
  5. SIGUSR1 status output
  6. 100 concurrent connections
  7. SIGTERM exits 0

Usage: python3 verify/acceptance.py <path-to-gopf-binary>
"""
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/gopf")
WORK = os.path.dirname(os.path.abspath(__file__))
TMP = os.path.join(WORK, "_tmp")
os.makedirs(TMP, exist_ok=True)

failures = []


def check(name, ok, detail=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  :: " + detail))
    if not ok:
        failures.append(name)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Backend:
    """TCP server that reads until EOF, then replies name:len:payload and closes.

    Requires the client half-close to be propagated by the proxy; also used to
    test backend-initiated close (greet=True sends first, without waiting).
    """

    def __init__(self, name, greet=False):
        self.name = name
        self.greet = greet
        self.port = free_port()
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", self.port))
        self.sock.listen(128)
        self.hits = 0
        self.lock = threading.Lock()
        self.stop = False
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stop:
            try:
                self.sock.settimeout(0.3)
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        with self.lock:
            self.hits += 1
        try:
            conn.settimeout(3)
            if self.greet:
                conn.sendall(b"HELLO:" + self.name.encode())
                conn.close()
                return
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            conn.sendall(self.name.encode() + b":" + str(len(data)).encode() + b":" + data)
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def close(self):
        self.stop = True
        try:
            self.sock.close()
        except OSError:
            pass


class ImmediateBackend:
    """Replies immediately after the first request read, without waiting for EOF.

    Models an HTTP server: request/response must flow while the client keeps its
    write side open. Any proxy that buffers until EOF will deadlock here.
    """

    def __init__(self, body):
        self.body = body
        self.port = free_port()
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", self.port))
        self.sock.listen(128)
        self.stop = False
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        while not self.stop:
            try:
                self.sock.settimeout(0.3)
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        try:
            conn.settimeout(5)
            conn.recv(4096)
            conn.sendall(self.body)
        except OSError:
            pass
        finally:
            conn.close()

    def close(self):
        self.stop = True
        try:
            self.sock.close()
        except OSError:
            pass


class Proxy:
    def __init__(self, listen_port, config_path):
        self.log_path = os.path.join(TMP, "proxy.log")
        self.log = open(self.log_path, "w")
        self.port = listen_port
        self.proc = subprocess.Popen(
            [BIN, "-listen", f"127.0.0.1:{listen_port}", config_path],
            stdout=self.log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
        )
        self.wait_up()

    def wait_up(self):
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                    return
            except OSError:
                if self.proc.poll() is not None:
                    raise RuntimeError("proxy exited early: " + self.text())
                time.sleep(0.05)
        raise RuntimeError("proxy did not start listening")

    def text(self):
        self.log.flush()
        with open(self.log_path) as f:
            return f.read()

    def signal(self, sig):
        self.proc.send_signal(sig)

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(timeout=5)
        self.log.close()


def request(port, payload=b"hello", timeout=4.0):
    """Send payload, half-close, read reply. Returns reply bytes."""
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.settimeout(timeout)
    s.sendall(payload)
    s.shutdown(socket.SHUT_WR)  # the half-close the backend waits for
    out = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        out += chunk
    s.close()
    return out


def write_config(path, hosts):
    with open(path, "w") as f:
        # uppercase keys, like the Go sample config (tests case-insensitive parse)
        json.dump({"TrafficUrl": "", "Hosts": [{"Addr": a, "Weight": w} for a, w in hosts]}, f)


def main():
    if not os.path.isabs(BIN) or not os.path.exists(BIN):
        print("binary not found: " + BIN)
        return 2

    cfg = os.path.join(TMP, "settings.json")
    a = Backend("A")
    b = Backend("B")

    # ---- basic + half-close + weights 100/0 ----
    write_config(cfg, [("127.0.0.1:%d" % a.port, 100), ("127.0.0.1:%d" % b.port, 0)])
    listen = free_port()
    p = Proxy(listen, cfg)
    try:
        reply = request(listen, b"hello")
        check("forwarding + half-close (100/0 -> A)", reply == b"A:5:hello", repr(reply))

        # backend-initiated close reaches client
        c = Backend("C", greet=True)
        write_config(cfg, [("127.0.0.1:%d" % c.port, 100)])
        p.signal(signal.SIGHUP)
        time.sleep(0.3)
        s = socket.create_connection(("127.0.0.1", listen), timeout=4)
        s.settimeout(4)
        greeting = s.recv(4096)
        s.close()
        check("backend-initiated close", greeting == b"HELLO:C", repr(greeting))
        c.close()

        # ---- weighted 1/1 uses both ----
        write_config(cfg, [("127.0.0.1:%d" % a.port, 1), ("127.0.0.1:%d" % b.port, 1)])
        p.signal(signal.SIGHUP)
        time.sleep(0.3)
        a0, b0 = a.hits, b.hits
        for _ in range(40):
            request(listen, b"w")
        da, db = a.hits - a0, b.hits - b0
        check("weighted 1/1 hits both (A=%d B=%d)" % (da, db), da >= 8 and db >= 8, "skewed distribution")

        # ---- reload to a single host, no restart ----
        d = Backend("D")
        write_config(cfg, [("127.0.0.1:%d" % d.port, 100)])
        p.signal(signal.SIGHUP)
        time.sleep(0.4)
        reply = request(listen, b"after-reload")
        check("SIGHUP reload switches backend", reply == b"D:12:after-reload", repr(reply))

        # ---- failed reload must keep the previous config live ----
        with open(cfg, "w") as f:
            f.write('{"Hosts":[{"Addr":"not-an-addr","Weight":1}]}')
        p.signal(signal.SIGHUP)
        time.sleep(0.5)
        reply = request(listen, b"still-old")
        check("failed reload keeps old backend", reply == b"D:9:still-old", repr(reply))
        d.close()

        # ---- request/response while the client keeps its write side open ----
        imm = ImmediateBackend(b"x" * 396)
        write_config(cfg, [("127.0.0.1:%d" % imm.port, 100)])
        p.signal(signal.SIGHUP)
        time.sleep(0.4)
        s = socket.create_connection(("127.0.0.1", listen), timeout=5)
        s.settimeout(5)
        s.sendall(b"GET / HTTP/1.1\r\nHost: bench\r\nConnection: close\r\n\r\n")
        body = b""
        try:
            while len(body) < 396:
                chunk = s.recv(4096)
                if not chunk:
                    break
                body += chunk
        except socket.timeout:
            pass
        s.close()
        check("HTTP-like request/response without client half-close",
              body == b"x" * 396, "got %d bytes (buffered until EOF?)" % len(body))
        imm.close()

        # ---- 1 MiB payload integrity (request/response, no half-close) ----
        import hashlib
        big = bytes(range(256)) * 4096  # exactly 1 MiB
        imm2 = ImmediateBackend(big)
        write_config(cfg, [("127.0.0.1:%d" % imm2.port, 100)])
        p.signal(signal.SIGHUP)
        time.sleep(0.4)
        s = socket.create_connection(("127.0.0.1", listen), timeout=10)
        s.settimeout(10)
        s.sendall(b"GET /big HTTP/1.1\r\nHost: bench\r\nConnection: close\r\n\r\n")
        got = b""
        try:
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                got += chunk
        except socket.timeout:
            pass
        s.close()
        check("1 MiB payload integrity",
              len(got) == len(big) and hashlib.sha256(got).digest() == hashlib.sha256(big).digest(),
              "got %d bytes, expected %d" % (len(got), len(big)))
        imm2.close()

        # ---- status signal ----
        p.signal(signal.SIGUSR1)
        time.sleep(0.4)
        txt = p.text()
        check("SIGUSR1 logs status", ("status" in txt.lower() or "connection" in txt.lower()),
              "log has no status line")

        # ---- concurrency (reload back to the two live backends) ----
        write_config(cfg, [("127.0.0.1:%d" % a.port, 1), ("127.0.0.1:%d" % b.port, 1)])
        p.signal(signal.SIGHUP)
        time.sleep(0.4)
        errs = []

        def worker(i):
            try:
                r = request(listen, ("c%d" % i).encode())
                if not r.startswith(b"A:") and not r.startswith(b"B:"):
                    errs.append("bad reply: " + repr(r))
            except Exception as e:  # noqa: BLE001
                errs.append(repr(e))

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(100)]
        t0 = time.time()
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=15)
        dt = time.time() - t0
        check("100 concurrent connections (%d errors, %.2fs)" % (len(errs), dt),
              not errs, (errs[:3] and repr(errs[:3])) or "")

        # ---- graceful exit ----
        p.signal(signal.SIGTERM)
        try:
            code = p.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            code = None
        check("SIGTERM exits 0", code == 0, "exit=%r" % code)
        if code is None:
            p.kill()
    finally:
        if p.proc.poll() is None:
            p.kill()
        a.close()
        b.close()

    print()
    if failures:
        print("FAILED:", ", ".join(failures))
        print("proxy log tail:")
        print("\n".join(p.text().splitlines()[-25:]))
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
