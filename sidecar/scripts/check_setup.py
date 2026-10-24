"""Drives the setup calibration (steps 1-3) against a running sidecar and prints each result.

Usage: uv run python scripts/check_setup.py PORT TOKEN   (see README "Testing setup")
"""
import asyncio, json, sys, time
import websockets

async def main(port, token):
    async with websockets.connect(f"ws://127.0.0.1:{port}/?token={token}", max_size=None) as ws:
        last = {}
        async def pump(until, timeout):
            t0 = time.time()
            while time.time() - t0 < timeout:
                raw = await asyncio.wait_for(ws.recv(), timeout)
                if isinstance(raw, bytes):
                    continue
                m = json.loads(raw)
                last[m["type"]] = m
                if until(m):
                    return m
            return None
        await pump(lambda m: m["type"] == "status", 15)
        await asyncio.sleep(3)
        await pump(lambda m: m["type"] == "metrics", 5)
        mt = last["metrics"]
        print("camera_ok", last["status"].get("camera_ok"), "face_present", mt.get("face_present"), "calibrated", mt.get("calibrated"))
        for step, dur in ((1, 3), (2, 10), (3, 60)):
            await ws.send(json.dumps({"type": "command", "name": "calibrate", "args": {"step": step}}))
            targets = []
            def done(m):
                if m["type"] == "calibration" and m.get("target") and (not targets or targets[-1] != m["target"]):
                    targets.append(m["target"])
                return m["type"] == "calibration" and m.get("step") == step and m["phase"] in ("done", "failed")
            m = await pump(done, dur + 20)
            print(f"step {step}:", m and m["phase"], json.dumps(m and m.get("result")), "targets" if targets else "", targets or "")
            if not m or m["phase"] != "done":
                return
        await pump(lambda m: m["type"] == "status", 5)
        await asyncio.sleep(1.5)
        await pump(lambda m: m["type"] == "metrics", 5)
        mt = last["metrics"]
        print("after: calibrated", mt.get("calibrated"), "eye_score", mt.get("eye_score"), "zen", last["status"].get("zen"))

asyncio.run(main(int(sys.argv[1]), sys.argv[2]))
