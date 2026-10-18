#!/usr/bin/env python3
"""Test-only mock of the oMLX server API, used by CI to exercise SiliconPulse's oMLX detection end to end.

It is started exactly the way the oMLX app starts its server (`python3 -m omlx.cli serve`), on a
non-default port, so detection has to work as it does for a real server (process + listening socket,
not a guessed port):

    MOCK_OMLX_PORT=8765 PYTHONPATH=scripts/mock-omlx python3 -m omlx.cli serve

Serves on loopback only: /health, /v1/models, /v1/models/status and /api/status, shaped like oMLX's own
handlers. One of three models is loaded; a request is "active" for 8 s of every 20 s, offset from the
llama-server mock. The model names say "mock" so CI screenshots cannot be mistaken for a real runner.
"""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

START = time.time()
PORT = int(os.environ.get("MOCK_OMLX_PORT", "8765"))
LOADED = "mock-Qwen3-8B-4bit"
SIZE = 4_617_089_843


def active() -> bool:
    return (int(time.time() - START) + 10) % 20 < 8


def completed_requests() -> int:
    return int((time.time() - START + 10) // 20)


def models_status():
    return {
        "final_ceiling": 0, "current_model_memory": SIZE, "model_count": 3, "loaded_count": 1,
        "models": [
            {"id": LOADED, "loaded": True, "is_loading": False, "estimated_size": SIZE, "actual_size": SIZE,
             "pinned": False, "engine_type": "batched", "model_type": "llm", "config_model_type": "qwen3",
             "model_context_length": 40960, "max_context_window": 32768, "is_helper": False},
            {"id": "mock-gemma-3-12b-it-4bit", "loaded": False, "is_loading": False, "estimated_size": 7_100_000_000,
             "actual_size": None, "model_type": "vlm"},
            {"id": "mock-bge-m3", "loaded": False, "is_loading": False, "estimated_size": 600_000_000, "model_type": "embedding"},
        ],
    }


def api_status():
    done = completed_requests()
    return {
        "status": "ok", "version": "0.0.0-mock", "uptime_seconds": round(time.time() - START, 1),
        "models_discovered": 3, "models_loaded": 1, "models_loading": 0, "default_model": LOADED,
        "loaded_models": [LOADED], "total_requests": done, "active_requests": 1 if active() else 0,
        "waiting_requests": 0, "total_prompt_tokens": done * 300, "total_completion_tokens": done * 420,
        "avg_generation_tps": 52.4 if done else 0.0, "model_memory_used": SIZE, "model_memory_max": None,
    }


ROUTES = {
    "/health": lambda: {"status": "healthy", "default_model": LOADED,
                        "engine_pool": {"model_count": 3, "loaded_count": 1, "final_ceiling": 0, "current_model_memory": SIZE},
                        "mcp": None},
    "/v1/models": lambda: {"object": "list", "data": [{"id": m["id"], "object": "model", "owned_by": "omlx"}
                                                      for m in models_status()["models"]]},
    "/v1/models/status": models_status,
    "/api/status": api_status,
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        route = ROUTES.get(self.path)
        if route is None:
            self.send_response(404)
            self.end_headers()
            return
        data = json.dumps(route()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"Mock oMLX listening on 127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
