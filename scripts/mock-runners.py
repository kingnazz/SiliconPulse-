#!/usr/bin/env python3
"""Test-only mock of local AI runner APIs, used by CI to exercise SiliconPulse's AI detection end to end.

Serves on loopback only:
  * Ollama API on 127.0.0.1:11434 (/api/ps, /api/version): one model whose keep-alive timer is
    refreshed every 20 s, as if a request had just been served.
  * llama-server API on 127.0.0.1:8080 (/props, /slots, /metrics, /v1/models): generation counters advance
    at ~40 tok/s during 10 s bursts every 20 s.

The model names say "mock" so screenshots taken in CI cannot be mistaken for a real runner.
"""
import json
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

START = time.time()


def generating() -> bool:
    return int(time.time() - START) % 20 < 10


def generated_tokens() -> tuple[float, float]:
    """(tokens predicted, seconds spent predicting) so far."""
    elapsed = time.time() - START
    cycles, phase = divmod(elapsed, 20)
    busy = cycles * 10 + min(phase, 10)
    return busy * 40.0, busy


class Handler(BaseHTTPRequestHandler):
    routes: dict = {}

    def do_GET(self):  # noqa: N802
        route = self.routes.get(self.path)
        if route is None:
            self.send_response(404)
            self.end_headers()
            return
        body, content_type = route()
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def ollama_routes():
    def ps():
        refreshed = START + (int(time.time() - START) // 20) * 20
        expires = datetime.fromtimestamp(refreshed, timezone.utc) + timedelta(minutes=5)
        return json.dumps({"models": [{
            "name": "mock-qwen3:30b-a3b", "model": "mock-qwen3:30b-a3b", "size": 19532111872,
            "size_vram": 19532111872, "context_length": 8192, "expires_at": expires.isoformat(),
            "details": {"format": "gguf", "family": "qwen3moe", "parameter_size": "30.5B", "quantization_level": "Q4_K_M"},
        }]}), "application/json"

    return {"/api/ps": ps, "/api/version": lambda: (json.dumps({"version": "0.0.0-mock"}), "application/json")}


def llama_routes():
    def props():
        return json.dumps({"default_generation_settings": {"n_ctx": 8192}, "total_slots": 1,
                           "model_path": "/models/Mock-Llama-3.2-3B-Q4_K_M.gguf", "build_info": "mock"}), "application/json"

    def slots():
        tokens, _ = generated_tokens()
        return json.dumps([{"id": 0, "n_ctx": 8192, "is_processing": generating(),
                            "next_token": {"n_decoded": int(tokens) % 4096}}]), "application/json"

    def metrics():
        tokens, seconds = generated_tokens()
        return (f"llamacpp:tokens_predicted_total {tokens:.0f}\n"
                f"llamacpp:tokens_predicted_seconds_total {seconds:.3f}\n"
                f"llamacpp:requests_processing {1 if generating() else 0}\n"), "text/plain"

    def models():
        return json.dumps({"object": "list", "data": [{"id": "Mock-Llama-3.2-3B-Q4_K_M"}]}), "application/json"

    return {"/props": props, "/slots": slots, "/metrics": metrics, "/v1/models": models}


def serve(port, routes):
    handler = type(f"Handler{port}", (Handler,), {"routes": routes})
    ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()


if __name__ == "__main__":
    for port, routes in ((11434, ollama_routes()), (8080, llama_routes())):
        threading.Thread(target=serve, args=(port, routes), daemon=True).start()
    print("Mock runners listening on 127.0.0.1:11434 (Ollama) and 127.0.0.1:8080 (llama-server)", flush=True)
    while True:
        time.sleep(3600)
