# CloudAnchor: Final Runtime Verification & Root-Cause Audit Report

**Audit Date:** 2026-10-16 00:57 IST  
**Project Root:** `C:\Users\tharo\OneDrive\Documents\cloud_final`  
**Active Session ID:** `20261016-005653`  
**Current Public LocalTunnel URL:** `https://clear-llamas-brake.loca.lt`  

---

## 1. Verified Live Runtime State

All CloudAnchor services were freshly initialized via the root-level [`START.bat`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/START.bat) and are actively responding with HTTP 200:

| Service | PID | Port | Command Line / Identity | Verified Endpoint | HTTP Status |
|---|---|---|---|---|---|
| **Cloud API** | 19416 | 8001 | `python.exe -m uvicorn cloud_api.main:app --port 8001` | `http://127.0.0.1:8001/health` | **200 OK** |
| **Fog Gateway** | 13940 | 8000 | `python.exe -m uvicorn backend.main:app --port 8000` | `http://127.0.0.1:8000/health` | **200 OK** |
| **Web Dashboard** | 21596 | 5173 | `npm.cmd run dev -- --host` (Vite) | `http://127.0.0.1:5173/` | **200 OK** |
| **Public LocalTunnel** | 28336 | 8000 | `npx localtunnel --port 8000` | `https://clear-llamas-brake.loca.lt/health` | **200 OK** |
| **Telemetry Bridge** | 32660 | N/A | `cmd.exe /c title ... & python tinkercad\tinkercad_bridge.py` | Dedicated Interactive Window | **ACTIVE** |

*Note: Port checks confirmed zero duplicate processes. Ports 8000, 8001, and 5173 have exactly one listening owner.*

---

## 2. Root Cause Analysis & Audit of Architectural Modifications

### A. Investigation of `ACTIVE_SESSION_ID = "SIM-DEFAULT"`
- **Vulnerability Identified**: 
  In [`backend/database.py`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/backend/database.py), `archive_legacy_pending_records()` contained a blanket clause:
  `WHERE status = 'PENDING' AND (session_id = 'SIM-DEFAULT' OR ...)`
  Whenever the gateway restarted, `startup_event()` invoked this archive function, which immediately marked all `PENDING` records in `SIM-DEFAULT` as `FAILED` with `'Legacy simulator record archived'`. Furthermore, because `sync_worker_thread()` passed `session_id=target_sess`, any records buffered under earlier timestamped sessions during an outage were ignored across restarts.
- **Root-Cause Resolution**:
  1. Removed `session_id = 'SIM-DEFAULT' OR` from `archive_legacy_pending_records()`. Archiving now exclusively targets known legacy mock prefixes (`REQ-406%`, `REQ-224%`, `REQ-UNIT-%`, `REQ-FIFO-%`, `REQ-DUP-%`, or devices `'ESP32-001'`, `'ESP32-002'`, `'ARDUINO-002'`).
  2. Enhanced `sync_worker_thread()` in [`backend/main.py`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/backend/main.py): if the active session has no pending records, it falls back to draining any un-synced pending records across previous sessions (`get_pending_records(limit=20)`). No records are ever stranded across restarts.
  3. In `ingest_sensor_data()`, simulation resets (`req_id == "REQ-1"`) automatically generate a fresh timestamped session identifier (`SIM-YYYYMMDD-HHMMSS`).

### B. Audit of `taskkill.exe /PID <pid> /T /F` Process-Tree Safety
- **Vulnerability Investigated**: Could `taskkill /T /F` terminate processes not belonging to CloudAnchor?
- **Audit Finding**:
  In [`scripts/stop_services.ps1`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/scripts/stop_services.ps1), `Stop-ServiceProcessStrict` verifies the PID against WMI `Win32_Process` before issuing any kill command. It verifies:
  1. Process existence and PID.
  2. Command line match (`cloud_api.main:app`, `backend.main:app`, `npm run dev`/`vite`, `localtunnel`, `tinkercad_bridge.py`).
  3. Project path tokens (`cloud_final`).
  If unverified, the script explicitly rejects termination (`PROCESS OWNERSHIP REJECTED`).
  The `/T` flag only terminates processes where `ParentProcessId` traces back to the verified root service (such as `node.exe` under `npm.cmd`). Unrelated applications are never children of the verified CloudAnchor PID and remain untouched. This was empirically proven in Stage 7 with a live test server.

### C. Public Relay Timeout in Telemetry Bridge
- **Vulnerability Identified**: The public LocalTunnel server relay (`https://*.loca.lt`) incurs residential DNS/TLS latency up to 12–15 seconds during peak traffic. A hardcoded 15.0s timeout caused occasional `[BRIDGE TIMEOUT]` dropouts.
- **Root-Cause Resolution**: Increased the HTTP timeout in [`tinkercad/tinkercad_bridge.py`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/tinkercad/tinkercad_bridge.py) to `25.0` seconds.

### D. Automated Launcher Non-Blocking Flag
- **Improvement**: Added `--no-pause` parameter support to both [`START.bat`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/START.bat) and [`STOP.bat`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/STOP.bat) so automated verification harnesses run cleanly without waiting for interactive keystrokes, while preserving `pause` when double-clicked by the user in Explorer.

---

## 3. Comprehensive Verification Test Suite Results

| Test ID | Test Description | Observed Output / Evidence | Status |
|---|---|---|---|
| **Test 1** | Runtime State & HTTP Probes | `http://127.0.0.1:8001/health` (200 OK)<br>`http://127.0.0.1:8000/health` (200 OK)<br>`http://127.0.0.1:5173/` (200 OK)<br>`https://clear-llamas-brake.loca.lt/health` (200 OK) | **PASS** |
| **Test 2** | Code Audit & Session Safety | Verified in `database.py` and `main.py`. Pending records survive restarts; cross-session un-synced queue fallback enabled. | **PASS** |
| **Test 3** | Fresh Startup via `START.bat` | Ran `START.bat`. Resolved `%~dp0`. Detected ports clean. LocalTunnel assigned and public reachability verified. Services spawned detached. | **PASS** |
| **Test 4** | End-to-End Telemetry Flow | Ingested `REQ-AUDIT-92200` via public LocalTunnel relay.<br>1. Bridge validated JSON<br>2. Gateway accepted (HTTP 200)<br>3. Stored in `gateway.db` (id=23427)<br>4. Sync worker forwarded to Cloud API<br>5. Verified in `cloud.db` (`REQ-AUDIT-92200`, 26.85°C)<br>6. Gateway log stream synced; status: `SYNCED`. | **PASS** |
| **Test 5** | Outage & Resilient Recovery | 1. Simulated outage: `POST /control {"status":"OFFLINE"}`<br>2. Ingested `REQ-OUTAGE-AUDIT-92246`<br>3. Local queue retained record as `PENDING`<br>4. Cloud DB count: 0<br>5. Restored: `POST /control {"status":"ONLINE"}`<br>6. Sync worker drained record at T+3s to `SYNCED`<br>7. Cloud DB contains exactly 1 copy. | **PASS** |
| **Test 6** | Dynamic URL Handling & Fail-Closed | Dynamic edit to `tunnel_url.txt` triggered immediate reload (`has_changed=True`). Empty, malformed, or missing file returned `""` with zero fallback to stale URLs. Live public probe returned HTTP 200. | **PASS** |
| **Test 7** | Safe Shutdown (`STOP.bat`) & DB Preservation | 1. Spawned unrelated Python server (PID 3748) on port 9991.<br>2. Executed `STOP.bat --no-pause`.<br>3. Stopped services in reverse order; ports freed.<br>4. Unrelated process survived untouched.<br>5. SQLite counts preserved (`gateway.db`: 23364, `cloud.db`: 23111). | **PASS** |
| **Test 8** | Clean Restart & Recovery | Re-executed `START.bat`. New session `20261016-005653` initialized. Public URL `https://clear-llamas-brake.loca.lt` verified healthy. | **PASS** |
| **Test 9** | Regression Unit Test Suite | Executed `python -m unittest discover -s tests`. Ran 37 tests in 11.701s; 0 failures, 0 errors. | **PASS** |
| **Test 10** | Real Tinkercad Circuit Hardware Simulation | Physical Tinkercad web browser clipboard input and physical serial monitor streaming require interactive manual trigger. | **REQUIRES MANUAL VERIFICATION** |

---

## 4. Modified Files Summary

1. [`backend/database.py`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/backend/database.py):
   - Removed blanket `session_id = 'SIM-DEFAULT' OR` clause from `archive_legacy_pending_records()` to prevent premature marking of pending records as `FAILED` on gateway restart.
2. [`backend/main.py`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/backend/main.py):
   - In `sync_worker_thread()`, added fallback to drain any un-synced pending records across previous sessions (`get_pending_records(limit=20)`).
   - In `ingest_sensor_data()`, simulation resets (`req_id == "REQ-1"`) generate unique timestamped sessions (`SIM-YYYYMMDD-HHMMSS`).
3. [`tinkercad/tinkercad_bridge.py`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/tinkercad/tinkercad_bridge.py):
   - Increased request timeout from 15.0s to 25.0s to accommodate residential LocalTunnel relay latency.
4. [`START.bat`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/START.bat) & [`STOP.bat`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/STOP.bat):
   - Added support for `--no-pause` parameter for automated testing while keeping user interactive pause on double-click.

---

## 5. Next Steps for You

Your CloudAnchor system is running right now:

1. **Open the Web Dashboard**:
   Navigate to [http://localhost:5173](http://localhost:5173) in your browser.
2. **Perform the Tinkercad Demonstration**:
   - In your open **CloudAnchor - Tinkercad Telemetry Bridge** console window, paste JSON telemetry lines from the Tinkercad Serial Monitor (or let your serial bridge feed it).
   - Note that the current public ingestion endpoint is:
     `https://clear-llamas-brake.loca.lt/api/ingest`
   - Verify on the dashboard that request IDs match the Tinkercad Arduino request counter (`REQ-1`, `REQ-2`, `REQ-3`, ...).
3. **When Finished**:
   Double-click [`STOP.bat`](file:///C:/Users/tharo/OneDrive/Documents/cloud_final/STOP.bat) to safely shut down all services. All SQLite database records and telemetry logs will remain preserved.
