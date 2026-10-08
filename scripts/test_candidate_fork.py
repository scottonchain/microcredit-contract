import os, socket, sys, tempfile, threading, unittest
import candidate_fork as f

SERVER = """
import http.server, sys, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length', 0)))
        b = json.dumps({"jsonrpc": "2.0", "id": 1, "result": "0x14a34"}).encode()
        self.send_response(200); self.send_header('content-type', 'application/json'); self.send_header('content-length', str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
"""


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class ForkTest(unittest.TestCase):
    """Codex review 5463115207: a restart that failed with 'Address already in use' was read as a fresh fork."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.log = os.path.join(self.dir, "anvil.log")
        self.pidfile = os.path.join(self.dir, "anvil.pid")
        self.port = free_port()
        self.started = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for pid in self.started:
            if f.alive(pid):
                os.kill(pid, 9)

    def server_argv(self):
        return [sys.executable, "-c", SERVER, str(self.port)]

    def test_a_healthy_fork_starts_is_recorded_and_stops_with_its_port_freed(self):
        pid = f.start(self.server_argv(), self.port, self.log, self.pidfile, ready_timeout=20)
        self.started.append(pid)
        self.assertTrue(f.alive(pid))
        with open(self.pidfile) as fh:
            self.assertEqual(fh.read(), str(pid))
        self.assertTrue(f.port_open(self.port))
        f.stop(self.pidfile, self.port)
        self.assertFalse(f.alive(pid))
        self.assertFalse(f.port_open(self.port))
        self.assertFalse(os.path.exists(self.pidfile))

    def test_a_port_that_already_answers_is_refused_before_anything_starts(self):
        stale = socket.socket()
        stale.bind(("127.0.0.1", self.port))
        stale.listen(256)
        self.addCleanup(stale.close)
        with self.assertRaisesRegex(f.ForkError, "already answers"):
            f.start(self.server_argv(), self.port, self.log, self.pidfile, ready_timeout=5)
        self.assertFalse(os.path.exists(self.pidfile))

    def test_a_child_that_exits_is_a_failure_not_a_ready_fork(self):
        argv = [sys.executable, "-c", "import sys; print('boom'); sys.exit(3)"]
        with self.assertRaisesRegex(f.ForkError, "exited with 3"):
            f.start(argv, self.port, self.log, self.pidfile, probe=lambda p: False, ready_timeout=10)
        self.assertFalse(os.path.exists(self.pidfile))

    def test_a_stale_endpoint_answering_cannot_hide_a_child_that_could_not_bind(self):
        # the probe is answered by someone else (the old fork); our child reports the port is taken and idles
        argv = [sys.executable, "-c", "import time; print('Error: Address already in use (os error 98)', flush=True); time.sleep(60)"]
        with self.assertRaisesRegex(f.ForkError, "could not bind"):
            f.start(argv, self.port, self.log, self.pidfile, probe=lambda p: True, ready_timeout=10)
        self.assertFalse(os.path.exists(self.pidfile))

    def test_a_fork_that_never_answers_times_out_and_is_killed(self):
        argv = [sys.executable, "-c", "import time; time.sleep(60)"]
        with self.assertRaisesRegex(f.ForkError, "did not answer"):
            f.start(argv, self.port, self.log, self.pidfile, probe=lambda p: False, ready_timeout=1)

    def test_stop_refuses_to_report_success_while_a_foreign_process_holds_the_port(self):
        foreign = socket.socket()
        foreign.bind(("127.0.0.1", self.port))
        foreign.listen(256)
        self.addCleanup(foreign.close)
        with self.assertRaisesRegex(f.ForkError, "another process owns it"):
            f.stop(self.pidfile, self.port, timeout=1)

    def test_stop_without_a_pidfile_on_a_free_port_is_a_no_op(self):
        f.stop(self.pidfile, self.port, timeout=1)


if __name__ == "__main__":
    unittest.main()
