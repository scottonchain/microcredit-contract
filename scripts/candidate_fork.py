#!/usr/bin/env python3
"""Start and stop the local Anvil fork used by candidate_evidence.sh, and pin one Base Sepolia block for every fork of a run.

  candidate_fork.py block --rpc URL [--back 3]               print "<number> <hash>" of a block a few behind the head
  candidate_fork.py start --rpc URL --block N --port P --log FILE --pidfile FILE [--anvil anvil]
  candidate_fork.py stop  --pidfile FILE --port P

Why a helper: the first evidence run on 726fa11 (Codex review 5463115207) restarted Anvil with `pkill; sleep 1`, the new child
failed with "Address already in use", and the readiness probe connected to the previous, already-used fork, so the default-path
rehearsal ran on a stale chain. Here `start` refuses a port that already answers, watches its own child while it waits, and
fails if the child exits or logs that the address is in use; `stop` ends exactly the recorded process and waits for the port
to free. Standard library only.
"""
import argparse, json, os, signal, socket, subprocess, sys, time, urllib.request


class ForkError(RuntimeError):
    pass


def port_open(port, host="127.0.0.1"):
    with socket.socket() as s:
        s.settimeout(0.5)
        return s.connect_ex((host, port)) == 0


def chain_id_probe(port):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}).encode()
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{port}", body, {"content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=2) as r:
            return "result" in json.load(r)
    except Exception:
        return False


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, body, {"content-type": "application/json", "user-agent": "candidate-fork/1"})
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if "error" in out:
        raise ForkError(f"{method}: {out['error']}")
    return out["result"]


def pinned_block(url, back=3):
    head = int(rpc(url, "eth_blockNumber", []), 16)
    n = head - back
    blk = rpc(url, "eth_getBlockByNumber", [hex(n), False])
    return n, blk["hash"]


def alive(pid):
    """True while `pid` is a running process. No /proc: in a PID namespace its numbers need not match the ones fork returns
    (Codex review 5463220882: a stopped child kept being read as alive)."""
    try:
        done, _ = os.waitpid(pid, os.WNOHANG)  # our own child: this also reaps it once it has exited
        return done != pid
    except ChildProcessError:
        pass  # not our child (an earlier helper process started it): signal 0 is all that is left
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def start(argv, port, log_path, pidfile, probe=chain_id_probe, ready_timeout=90.0):
    """Launch argv (an Anvil command listening on `port`) and return its pid once it is ready and verified to be ours."""
    if port_open(port):
        raise ForkError(f"port {port} already answers: a previous fork is still running; stop it first")
    log = open(log_path, "wb")
    proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    log.close()

    def text():
        with open(log_path, "rb") as f:
            return f.read().decode(errors="replace")

    def fail(msg):
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        raise ForkError(f"{msg}; child log:\n{text()[-800:]}")

    deadline = time.time() + ready_timeout
    while True:
        if proc.poll() is not None:
            fail(f"the fork process exited with {proc.returncode} before it was ready")
        if "address already in use" in text().lower():
            fail("the fork process could not bind its port")
        if probe(port):
            break
        if time.time() > deadline:
            fail(f"the fork did not answer within {ready_timeout:.0f}s")
        time.sleep(0.25)
    time.sleep(0.5)  # a late bind failure shows up right after the first answer; the answer must come from this child
    if proc.poll() is not None or "address already in use" in text().lower():
        fail("the fork process died or could not bind after the first answer")
    with open(pidfile, "w") as f:
        f.write(str(proc.pid))
    proc._child_created = False  # the fork deliberately outlives this process; do not warn when the Popen object is dropped
    return proc.pid


def stop(pidfile, port, timeout=15.0):
    """End exactly the recorded process, wait for it and for the port to free, then remove the pidfile."""
    if os.path.exists(pidfile):
        with open(pidfile) as f:
            pid = int(f.read().strip())
        if alive(pid):
            os.kill(pid, signal.SIGTERM)
            end = time.time() + timeout
            while alive(pid) and time.time() < end:
                time.sleep(0.1)
            if alive(pid):
                os.kill(pid, signal.SIGKILL)
                end = time.time() + 5
                while alive(pid) and time.time() < end:
                    time.sleep(0.1)
            if alive(pid) and port_open(port):
                raise ForkError(f"pid {pid} would not stop")
            # SIGKILL cannot be ignored: a pid that still answers signal 0 while its port is closed is an exited child that
            # nobody has reaped yet (its parent was the earlier helper process), not a running fork.
        os.remove(pidfile)
    end = time.time() + timeout
    while port_open(port) and time.time() < end:
        time.sleep(0.1)
    if port_open(port):
        raise ForkError(f"port {port} still answers after the recorded fork was stopped: another process owns it")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("block"); b.add_argument("--rpc", required=True); b.add_argument("--back", type=int, default=3)
    s = sub.add_parser("start")
    s.add_argument("--rpc", required=True); s.add_argument("--block", type=int, required=True); s.add_argument("--port", type=int, default=8546)
    s.add_argument("--log", required=True); s.add_argument("--pidfile", required=True); s.add_argument("--anvil", default="anvil")
    t = sub.add_parser("stop"); t.add_argument("--pidfile", required=True); t.add_argument("--port", type=int, default=8546)
    a = ap.parse_args()
    try:
        if a.cmd == "block":
            n, h = pinned_block(a.rpc, a.back)
            print(n, h)
        elif a.cmd == "start":
            argv = [a.anvil, "--fork-url", a.rpc, "--fork-block-number", str(a.block), "--chain-id", "84532", "--port", str(a.port), "--silent"]
            print(start(argv, a.port, a.log, a.pidfile))
        else:
            stop(a.pidfile, a.port)
    except ForkError as e:
        print(f"candidate_fork: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
