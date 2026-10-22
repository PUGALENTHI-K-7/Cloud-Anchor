import sys
import os
import json
import time
import urllib.parse
from typing import Optional, Tuple
import requests

# Resolve Project Root reliably from this script's physical location
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
DEFAULT_TUNNEL_FILE = os.path.join(PROJECT_ROOT, "tunnel_url.txt")

# State tracking for dynamic URL reloading
ACTIVE_ENDPOINT: str = ""
CURRENT_URL_FILE: Optional[str] = None
LAST_FILE_MTIME: float = 0.0

def construct_endpoint(raw_url: str, allow_http: bool = False) -> str:
    """
    Validates the base URL and ensures /api/ingest is appended exactly once.
    - Strips whitespace
    - Ensures valid scheme (HTTPS required unless local override)
    - Validates domain/netloc
    - Normalizes slashes and appends /api/ingest
    """
    cleaned = raw_url.strip().rstrip('/')
    if not cleaned:
        raise ValueError("URL cannot be empty.")

    parsed = urllib.parse.urlparse(cleaned)
    if not parsed.scheme or not parsed.netloc:
        raise ValueError(f"Malformed URL '{raw_url}'. Scheme and host are required.")

    if not allow_http and parsed.scheme.lower() != "https":
        raise ValueError(f"Insecure scheme '{parsed.scheme}://'. LocalTunnel URL must use HTTPS (e.g. https://xxxx.loca.lt).")

    # Normalize path to ensure /api/ingest is appended exactly once
    path = parsed.path.rstrip('/')
    if path.lower().endswith("/api/ingest"):
        final_path = path
    elif path:
        final_path = f"{path}/api/ingest"
    else:
        final_path = "/api/ingest"

    return urllib.parse.urlunparse((parsed.scheme, parsed.netloc, final_path, "", "", ""))

def locate_tunnel_file() -> Optional[str]:
    """Finds the active tunnel_url.txt from explicit arguments, env vars, or standard locations."""
    # 1. CLI --config flag
    for i, arg in enumerate(sys.argv[1:], start=1):
        if arg in ["--config", "-c"] and i < len(sys.argv) - 1:
            cfg = os.path.abspath(sys.argv[i + 1].strip())
            if os.path.isfile(cfg):
                return cfg

    # 2. Environment variables
    env_cfg = os.environ.get("CLOUDANCHOR_TUNNEL_FILE") or os.environ.get("TUNNEL_URL_FILE")
    if env_cfg and os.path.isfile(env_cfg):
        return os.path.abspath(env_cfg)

    # 3. Standard locations: Project Root, then CWD
    candidates = [
        DEFAULT_TUNNEL_FILE,
        os.path.join(os.getcwd(), "tunnel_url.txt")
    ]
    for p in candidates:
        if os.path.isfile(p):
            return os.path.abspath(p)

    return None

def resolve_gateway_endpoint(force_check: bool = False) -> Tuple[str, bool]:
    """
    Dynamically resolves or reloads the gateway endpoint.
    Returns (endpoint_url, has_changed).
    NEVER falls back to an old ACTIVE_ENDPOINT if the current configuration
    is missing, unreadable, empty, or malformed.
    """
    global ACTIVE_ENDPOINT, CURRENT_URL_FILE, LAST_FILE_MTIME

    # 1. Check CLI overrides first
    for i, arg in enumerate(sys.argv[1:], start=1):
        if arg == "--local":
            local_ep = "http://127.0.0.1:8000/api/ingest"
            changed = (ACTIVE_ENDPOINT != local_ep)
            ACTIVE_ENDPOINT = local_ep
            return ACTIVE_ENDPOINT, changed

        if arg in ["--url", "-u"] and i < len(sys.argv) - 1:
            override_url = sys.argv[i + 1].strip()
            try:
                ep = construct_endpoint(override_url, allow_http=override_url.startswith("http://localhost") or override_url.startswith("http://127.0.0.1"))
                changed = (ACTIVE_ENDPOINT != ep)
                ACTIVE_ENDPOINT = ep
                return ACTIVE_ENDPOINT, changed
            except ValueError as ve:
                ACTIVE_ENDPOINT = ""
                print(f"[BRIDGE CONFIG ERROR] Invalid --url argument: {ve}")
                return "", False

    # 2. Locate tunnel_url.txt
    url_file = locate_tunnel_file()
    if not url_file or not os.path.isfile(url_file):
        ACTIVE_ENDPOINT = ""
        CURRENT_URL_FILE = None
        LAST_FILE_MTIME = 0.0
        return "", False

    CURRENT_URL_FILE = url_file
    try:
        mtime = os.path.getmtime(url_file)
    except OSError:
        ACTIVE_ENDPOINT = ""
        return "", False

    # If file mtime hasn't changed and endpoint is already valid, return it
    if not force_check and mtime == LAST_FILE_MTIME and ACTIVE_ENDPOINT:
        return ACTIVE_ENDPOINT, False

    # 3. Read configuration file
    try:
        with open(url_file, "r", encoding="utf-8-sig") as f:
            raw_url = f.read().strip().lstrip('\ufeff')
    except Exception as e:
        ACTIVE_ENDPOINT = ""
        print(f"[BRIDGE CONFIG ERROR] Could not read configuration '{url_file}': {e}")
        return "", False

    if not raw_url:
        ACTIVE_ENDPOINT = ""
        print(f"[BRIDGE CONFIG ERROR] Configuration file '{url_file}' is empty. Valid LocalTunnel URL is required.")
        return "", False

    # 4. Construct and validate endpoint
    try:
        new_ep = construct_endpoint(raw_url)
    except ValueError as ve:
        ACTIVE_ENDPOINT = ""
        print(f"[BRIDGE CONFIG ERROR] Invalid URL in '{url_file}': {ve}")
        return "", False

    changed = (new_ep != ACTIVE_ENDPOINT)
    ACTIVE_ENDPOINT = new_ep
    LAST_FILE_MTIME = mtime
    return ACTIVE_ENDPOINT, changed

def forward_json_line(line: str, target_url: Optional[str] = None):
    """
    Parses a single JSON line from Tinkercad Serial Monitor and forwards it
    to the active Fog Gateway ingestion endpoint with full resilience headers.
    """
    global ACTIVE_ENDPOINT
    line = line.strip()
    if not line:
        return

    # Check for dynamic URL updates before forwarding
    if not target_url:
        endpoint, changed = resolve_gateway_endpoint()
        if changed:
            print(f"[BRIDGE CONFIG] Detected updated LocalTunnel endpoint: {endpoint}")
        if not endpoint:
            print("[BRIDGE PAUSED] No valid LocalTunnel URL available. Telemetry submission paused until services are started.")
            return
    else:
        endpoint = target_url

    try:
        # Extract JSON substring if line contains extra characters
        start = line.find('{')
        end = line.rfind('}')
        if start != -1 and end != -1 and end > start:
            json_str = line[start:end+1]
            payload = json.loads(json_str)
        else:
            payload = json.loads(line)

        req_id = payload.get("request_id")
        if not req_id:
            print("[BRIDGE ERROR] Payload missing required 'request_id'. Record ignored.")
            return

        headers = {
            "Content-Type": "application/json",
            "bypass-tunnel-reminder": "true",
            "User-Agent": "CloudAnchorBridge/1.0"
        }

        print(f"[BRIDGE FORWARD] Preserving Authoritative {req_id} -> {endpoint}")
        res = requests.post(endpoint, json=payload, headers=headers, timeout=25.0)

        # Handle LocalTunnel interstitial / HTML warning pages
        content_type = res.headers.get("Content-Type", "")
        if "application/json" not in content_type:
            print(f"[BRIDGE ERROR] Gateway returned non-JSON response (possibly tunnel reminder or proxy error).")
            print(f"               HTTP {res.status_code} [{content_type}]: {res.text[:120]}")
            return

        try:
            resp_body = res.json()
        except Exception:
            resp_body = res.text

        if res.status_code in [200, 201]:
            q_status = resp_body.get("queue_status", "RECEIVED")
            cb_state = resp_body.get("circuit_breaker_state", "CLOSED")
            print(f"[GATEWAY RESPONSE] HTTP {res.status_code} OK | Queue: {q_status} | CB: {cb_state} | Message: {resp_body.get('message', '')}")
        else:
            print(f"[GATEWAY ERROR] HTTP {res.status_code}: {resp_body}")

    except json.JSONDecodeError as e:
        print(f"[BRIDGE PARSE ERROR] Invalid JSON string: {e}")
    except requests.exceptions.Timeout:
        print(f"[BRIDGE TIMEOUT] Request timed out connecting to {endpoint}. Local queue retains unsent records.")
    except requests.exceptions.ConnectionError as e:
        print(f"[BRIDGE CONNECTION ERROR] Could not connect to {endpoint}. Please check LocalTunnel status.")
    except Exception as e:
        print(f"[BRIDGE UNEXPECTED ERROR] {e}")

def main():
    endpoint, _ = resolve_gateway_endpoint(force_check=True)

    print("=" * 65)
    print("CloudAnchor - Tinkercad Serial Telemetry Bridge")
    print("Preserves Authoritative REQ-X from Arduino without modification")
    print("=" * 65)
    print(f"Project Root   : {PROJECT_ROOT}")
    print(f"Config Source  : {CURRENT_URL_FILE or 'CLI / Environment Override'}")
    print(f"Ingest Target  : {endpoint or '[UNAVAILABLE - Start CloudAnchor first]'}")
    print("=" * 65)

    if not endpoint:
        print("[BRIDGE CONFIG ERROR] tunnel_url.txt was not found or is empty.")
        print("Searched locations:")
        print(f"  - {DEFAULT_TUNNEL_FILE}")
        print(f"  - {os.path.join(os.getcwd(), 'tunnel_url.txt')}")
        print("Please run START.bat to start CloudAnchor services and generate a live LocalTunnel URL.")
        sys.exit(1)

    print("Instructions:")
    print(" 1. Copy JSON lines from your Tinkercad Serial Monitor.")
    print(" 2. Paste into this window and press ENTER.")
    print(" 3. Type 'exit' or press Ctrl+C to quit.")
    print('Example: {"request_id":"REQ-1","device_id":"ARDUINO-001","temperature":25.5,"humidity":56.4,"voltage":5.02}')
    print("=" * 65)

    while True:
        try:
            line = input("Arduino Serial > ")
            if line.strip().lower() in ["exit", "quit"]:
                print("Exiting bridge.")
                break
            forward_json_line(line)
        except (KeyboardInterrupt, EOFError):
            print("\nExiting bridge.")
            break

if __name__ == '__main__':
    main()
