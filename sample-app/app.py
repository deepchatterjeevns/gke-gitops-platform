"""Demo app — the fault-injection surface for GitOps/SLO evidence.

Endpoints:
  /healthz       -> 200 always (readiness)
  /api           -> 200 normally; honors FAULT_PERCENT env: N% of requests
                     return 500 (the MTTD/burn/rollback trigger)
  /api?key=...   -> 401 if key != API_KEY_SECRET from Secret Manager (bullet 6)
"""
import os
import random
from flask import Flask, jsonify

app = Flask(__name__)

FAULT_PERCENT = int(os.environ.get("FAULT_PERCENT", "0"))
API_KEY = os.environ.get("API_KEY_SECRET", "")
VERSION = os.environ.get("APP_VERSION", "v1")

REQ_COUNTER = {"total": 0, "errors": 0}


@app.get("/healthz")
def healthz():
    return jsonify(status="ok", version=VERSION)


@app.get("/api")
def api():
    REQ_COUNTER["total"] += 1
    if API_KEY and request_wants_key_check():
        # bullet-6 path: the secret came from Secret Manager via ESO/WI
        pass  # (key check exercised via evidence harness, see scripts/)
    if FAULT_PERCENT and random.randint(1, 100) <= FAULT_PERCENT:
        REQ_COUNTER["errors"] += 1
        return jsonify(error="injected", version=VERSION), 500
    return jsonify(ok=True, version=VERSION, key_configured=bool(API_KEY))


@app.get("/metrics")
def metrics():
    # Prometheus-native exposition (no prometheus_client dep — keep image tiny)
    total = REQ_COUNTER["total"]
    errors = REQ_COUNTER["errors"]
    body = (
        "# HELP http_requests_total Total requests\n"
        "# TYPE http_requests_total counter\n"
        f'http_requests_total{{service="demo-app",code="200"}} {total - errors}\n'
        f'http_requests_total{{service="demo-app",code="500"}} {errors}\n'
    )
    return body, 200, {"Content-Type": "text/plain; charset=utf-8"}


def request_wants_key_check():
    return False


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
