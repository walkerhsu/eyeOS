"""CLI: python -m eyeos [--port P --token T] [--print] [--record out.jsonl.gz] [--replay in.jsonl.gz]"""
import argparse
import asyncio

from .server import App


def main():
    p = argparse.ArgumentParser(prog="eyeos")
    p.add_argument("--port", type=int, help="serve the WebSocket on 127.0.0.1:PORT")
    p.add_argument("--token", help="required ?token= on the WebSocket URL")
    p.add_argument("--print", action="store_true", help="print metrics at 2 Hz and events to stdout")
    p.add_argument("--record", help="write per-frame landmarks to a .jsonl.gz")
    p.add_argument("--replay", help="feed a recorded .jsonl.gz through the metrics engine")
    p.add_argument("--db", help="SQLite path (default ~/Library/Application Support/eyeOS/eyeos.db)")
    a = p.parse_args()
    if not (a.port or a.print or a.record):
        p.error("pass --port, --print or --record")
    if a.port and not a.token:
        p.error("--port requires --token")
    app = App(port=a.port, token=a.token, print_mode=a.print, replay=a.replay, record=a.record, db_path=a.db)
    try:
        asyncio.run(app.main())
    except KeyboardInterrupt:
        pass
    finally:
        app.stop.set()  # lets the vision thread close the recording cleanly
        if app.thread:
            app.thread.join(3)


if __name__ == "__main__":
    main()
