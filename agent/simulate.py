"""Start the temporary APIs, run every agent service concurrently, then stop the APIs.

    .venv/bin/python simulate.py --turns 5
    .venv/bin/python simulate.py --turns 5 --fail-turn 2
    .venv/bin/python simulate.py --turns 3 --loop 30     # a round every 30 s until stopped
"""

from __future__ import annotations

import argparse
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from agents import AGENTS
from apis import SERVICES

HERE = Path(__file__).parent


def _wait_for_port(port: int, timeout_s: float = 10.0) -> None:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        with socket.socket() as sock:
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.1)
    raise RuntimeError(f"nothing listening on port {port}")


def _stop(*_: Any) -> None:
    raise SystemExit(0)


def _stop_all(processes: list[subprocess.Popen]) -> None:
    for process in processes:
        if process.poll() is None:
            process.terminate()
    for process in processes:
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()


def _run_round(turns: int, fail_turn: int) -> None:
    agents = []
    try:
        for name in AGENTS:
            command = [sys.executable, "run.py", "--agent", name, "--turns", str(turns)]
            if name == "support-agent" and fail_turn:
                command += ["--fail-turn", str(fail_turn)]
            agents.append(subprocess.Popen(command, cwd=HERE))
        for agent in agents:
            agent.wait()
    finally:
        _stop_all(agents)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--turns", type=int, default=5)
    parser.add_argument("--fail-turn", type=int, default=0, help="Passed to support-agent only.")
    parser.add_argument("--loop", type=float, default=0, help="Repeat a round every N seconds until stopped.")
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, _stop)
    apis = [
        subprocess.Popen([sys.executable, "apis.py", "--service", name], cwd=HERE)
        for name in SERVICES
    ]
    try:
        for service in SERVICES.values():
            _wait_for_port(service.port)
        while True:
            _run_round(args.turns, args.fail_turn)
            if not args.loop:
                break
            sys.stdout.flush()
            time.sleep(args.loop)
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        _stop_all(apis)


if __name__ == "__main__":
    main()
