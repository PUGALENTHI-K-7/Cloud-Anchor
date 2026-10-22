# CloudAnchor: A Multi-Sensor Fog-Assisted Resilient Gateway for Intermittent Cloud APIs

CloudAnchor is a complete, production-grade software prototype of a **Multi-Sensor Fog-Assisted Resilient IoT Gateway** designed to guarantee 100% data reliability, zero data loss, and rule-based edge intelligence in environments with intermittent cloud connectivity.

---

## 1. System Overview & Multi-Sensor Architecture

Traditional IoT setups transmit sensor readings directly to cloud endpoints. When cloud connectivity is severed or experiences outages, edge devices lose data. CloudAnchor resolves this by interposing an intelligent **Fog Gateway** that buffers data in an ACID-compliant local SQLite queue, enforces Circuit Breaking and Exponential Backoff, executes **Rule-Based Multi-Sensor Fusion**, and automatically synchronizes all records upon cloud restoration.

```
                          CLOUD LAYER
                ┌─────────────────────────────┐
                │          Cloud API          │
                │     FastAPI (Port 8001)     │
                │     SQLite (cloud.db)       │
                └──────────────┬──────────────┘
                               │
                          WAN / Internet
                               │
                               ▼
                           FOG LAYER
                ┌─────────────────────────────┐
                │     CloudAnchor Fog Gateway │
                │     FastAPI (Port 8000)     │
                │     SQLite (gateway.db)     │
                ├─────────────────────────────┤
                │ 1. Multi-Sensor Validation  │
                │ 2. Edge Fusion Intelligence │
                │ 3. Thread-Safe WAL Storage  │
                │ 4. Circuit Breaker FSM      │
                │ 5. Exponential Backoff Sync │
                │ 6. Real-Time Telemetry Cache│
                └──────────────┬──────────────┘
                               │
                         Local Network / LAN
                               │
                               ▼
                          EDGE LAYER
                ┌─────────────────────────────┐
                │  ESP32 Microcontroller      │
                │  (Wokwi / Device Simulator) │
                ├──────────────┬──────────────┤
                │ DHT22        │ Temp / Hum   │
                │ MPU6050      │ Accel / Vib  │
                │ INA219       │ V / I / Power│
                │ MQ-2         │ Gas / Smoke  │
                │ BMP280       │ Barometer    │
                └──────────────┴──────────────┘
```

---

## 2. Integrated Sensors

| Sensor | Protocol / Pin | Parameters Monitored | Purpose |
| :--- | :--- | :--- | :--- |
| **DHT22** | GPIO 15 (1-Wire) | Temperature (°C), Humidity (%) | Thermal & environmental baseline |
| **MPU6050** | I2C (SDA 21, SCL 22, 0x68) | Accel X/Y/Z, Vibration Index (g) | Mechanical vibration & structural stress |
| **INA219** | I2C (SDA 21, SCL 22, 0x40) | Voltage (V), Current (mA), Power (W) | Electrical monitoring & overcurrent detection |
| **MQ-2** | GPIO 34 (ADC1 Analog) | Gas & Smoke Concentration (ppm) | Hazardous air quality & fire warning |
| **BMP280** | I2C (SDA 21, SCL 22, 0x76) | Barometric Pressure (hPa) | Atmospheric monitoring |

---

## 3. Rule-Based Multi-Sensor Fusion Engine

The Fog Gateway runs an explainable, rule-based edge intelligence layer that fuses multi-sensor telemetry prior to persistence and forwarding:

- **Health Score ($0 - 100$)**: Computed from weighted deductions across thermal stress, mechanical vibration, electrical overcurrent, and gas concentration.
- **System Status**: `NORMAL`, `WARNING`, or `CRITICAL`.
- **Risk Level**: `LOW`, `MEDIUM`, or `HIGH`.
- **Warning Reason**: Dynamic diagnostic message detailing detected excursions (e.g. `"Elevated vibration (0.45g) and high current (620mA) detected"`).

Both **raw sensor data** and **derived fusion metrics** are preserved in SQLite storage and forwarded to the cloud.

---

## 4. Hardware & Wokwi Simulation

The Wokwi simulation files are organized under `wokwi-device/`:

- **Circuit Diagram**: `wokwi-device/diagram.json` (Includes ESP32 DevKit, DHT22, MPU6050, INA219, MQ-2, BMP280 with complete I2C wiring).
- **Firmware**: `wokwi-device/wokwi-device.ino` (Arduino C++ reading all 5 sensors, formatting JSON, and sending HTTP POST requests every 3 seconds).
- **Libraries**: `wokwi-device/libraries.txt` (Required Adafruit and ArduinoJson drivers).

---

## 5. Getting Started & Running

### Prerequisites
- **Python 3.8+**
- **Node.js 18+** & **npm**

### Step 1: Install Dependencies
```bash
pip install -r requirements.txt
cd frontend && npm install && cd ..
```

### Step 2: Automatic Launch (Windows PowerShell)
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\run_all.ps1
```

### Step 3: Manual Startup
Open separate terminal tabs:
1. **Cloud API (Port 8001)**:
   ```bash
   python -m uvicorn cloud_api.main:app --host 127.0.0.1 --port 8001
   ```
2. **Fog Gateway (Port 8000)**:
   ```bash
   python -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
   ```
3. **Frontend Dashboard (Port 5173)**:
   ```bash
   cd frontend && npm run dev
   ```
4. **Multi-Sensor Edge Simulator**:
   ```bash
   python simulator/device_simulator.py --interval 2.5 --devices 2
   ```

Open your browser at **`http://localhost:5173`**.

---

## 6. How to Test Cloud Resilience (Failure & Auto-Recovery)

1. **Normal Operation**:
   - Verify **Cloud Status** is `🟢 ONLINE`, **Gateway Mode** is `NORMAL`, and **Pending Queue** is `0`.
   - The multi-sensor timeseries chart streams live DHT22, MPU6050, and INA219 readings.
2. **Simulate Cloud Outage**:
   - In the **Resilience Lab** panel, click **`SIMULATE OUTAGE`** (or click **`Chaos Test (12s)`** in the toolbar).
   - Observe that **Cloud Status** becomes `🔴 OFFLINE` and **Gateway Mode** switches to `DEGRADED`.
   - After configured threshold failures (default: 3), the **Circuit Breaker** trips to `OPEN`.
   - All incoming multi-sensor packets are fast-failed to `gateway.db` with status `PENDING`.
3. **Restore Cloud & Auto-Recovery**:
   - Click **`RESTORE CLOUD`**.
   - Following cooldown, the Circuit Breaker enters `HALF-OPEN` and performs health probes.
   - Upon verification, the Circuit Breaker transitions to `CLOSED`.
   - The background FIFO sync worker drains all buffered records with exponential backoff and commits them to `cloud.db` with zero data loss!

---

## 7. Multi-Sensor JSON Telemetry Payload

```json
{
  "request_id": "REQ-20261005-001",
  "device_id": "ESP32-001",
  "timestamp": "2026-10-05 21:30:00",
  "temperature": 27.9,
  "humidity": 41.0,
  "acceleration_x": 0.02,
  "acceleration_y": 0.01,
  "acceleration_z": 0.98,
  "vibration_level": 0.03,
  "voltage": 5.01,
  "current": 120.5,
  "power": 0.60,
  "gas_level": 210,
  "pressure": 1013.2
}
```

---

## 8. Unit Test Suite

Run the full automated test suite covering Multi-Sensor Ingestion, Rule-Based Fusion, Queue Persistence, Circuit Breaking, and Exponential Backoff:
```bash
python -m unittest discover tests
```
*(All 37 unit tests pass with 100% success rate).*

---

## 9. Future Enhancements

- Physical ESP32 hardware testbench deployment.
- MQTT / CoAP / gRPC ingestion adapters.
- Distributed Fog Gateway clusters with RAFT leader election.
- Edge Machine Learning models (e.g. TinyML Random Forest / Autoencoders for predictive maintenance).
- Hardware security modules (HSM) with device X.509 mutual TLS certificates.
