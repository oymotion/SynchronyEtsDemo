# sensor-harmonyos

OYMotion Sensor SDK for HarmonyOS (ArkTS), plus an ArkTS demo app.

## Brief

OYMotion SDK is the software development kit for developers to access OYMotion
products. This project shows how to use the HarmonyOS binding (`sensor`,
an ArkTS Promise-style API over the C++ core) from an ArkTS app: scan,
connect, configure and stream EEG/ECG/EMG/IMU/PPG/SpO2 data, and replay
recorded bin files offline.

## Installation

The SDK ships as a prebuilt HAR (`libs/sensor.har`, contains the native
libraries for `arm64-v8a` and `x86_64`, the ArkTS binding classes and the
BLE bridge). Depend on it from the entry module's `oh-package.json5`:

```json5
"dependencies": {
  "sensor": "file:../libs/sensor.har"
}
```

then run `ohpm install` inside the `entry/` directory. A command-line
hvigor build does NOT install file dependencies automatically — the
`ohpm install` step (which links the HAR into `entry/oh_modules`) is
required once before the first `hvigorw assembleHap`. The HAR declares
compatibleSdkVersion 5.0.0(12); a consuming app must declare the same or
higher.

## 1. Permissions

Declare the Bluetooth permission in the module's `module.json5` and request
it from the user at runtime before scanning:

```json5
"requestPermissions": [
  {
    "name": "ohos.permission.ACCESS_BLUETOOTH",
    "reason": "$string:reason_access_bluetooth",
    "usedScene": {
      "abilities": ["EntryAbility"],
      "when": "inuse"
    }
  }
]
```

```ts
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';

const atManager = abilityAccessCtrl.createAtManager();
atManager.requestPermissionsFromUser(context, ['ohos.permission.ACCESS_BLUETOOTH']);
```

## 2. Initialize the SDK

```ts
import { SensorController, setBridge } from 'sensor';

// Register the BLE bridge once, before any scan/connect. The app files
// directory backs the SDK log / bin-temp defaults.
setBridge(context.filesDir);

const controller = SensorController.getInstance();

// Optional: redirect SDK logs (LOG_PATH must be set BEFORE DEBUG_ENABLED,
// and both must precede setBridge so the whole session lands in one
// directory)
controller.setParam('LOG_PATH', context.filesDir + '/sensorsdklog/<session>');
controller.setParam('DEBUG_ENABLED', 'True');

// Scan results arrive here
controller.setOnScanResultListener((devices) => {
  // BleDevice[]: name / mac / rssi; devices not yet connected
});
```

Use `getVersion()` to get the SDK version string.

## SensorController methods

### 1. Start scan

```ts
const ok = controller.startScan(6000);
```

`onScanResult` is invoked every `periodInMs` with the current device list.

### 2. Stop scan / check state

```ts
controller.stopScan();
const scanning = controller.isScanning();
const btOn = controller.isEnable();
controller.setOnEnableChangedListener((enabled) => { /* bluetooth on/off */ });
```

### 3. Create / get a SensorProfile

```ts
const profile = controller.requireSensor(mac);   // null when mac is invalid
const same    = controller.getSensor(mac);       // null when not created yet
const connected = controller.getConnectedSensors();
```

### 4. Synchronized multi-device stream start/stop

```ts
const results = await controller.multiStartDataNotification(sensors, 60000, -1, 5);
const stopResults = await controller.multiStopDataNotification(sensors);
// results: MultiDeviceResult[] { mac, ok, error }, input-order
// aligned; the actual start/stop writes are released back-to-back so the
// streams begin in sync
```

### 5. Terminate

```ts
SensorController.terminate();
```

Please MAKE SURE to call `terminate()` when the app exits. `onSuspend()` is
the app-went-to-background hook: it flushes every open bin capture and the
SDK log; it does not stop scanning/streaming.

## SensorProfile methods

### 6. Register listeners

```ts
profile.setOnStateChangeListener((p, newState) => {
  // DeviceState.CONNECTING / CONNECTED / READY / DISCONNECTED / ...
  // handle unexpected disconnects here
});
profile.setOnErrorListener((p, errorMsg) => {});
profile.setOnPowerListener((p, power) => {
  // battery 0-100 pushed periodically (see init)
});
profile.setOnDataListener((p, dataList) => {
  // SensorData[] batches after startDataNotification
  for (const data of dataList) { }
});
profile.setOnDeviceInfoUpdateListener((p, info) => {});
profile.setOnDataTransferStateChangeListener((p, isTransferring) => {});
```

A further listener, `setOnAutoReconnectListener`, customizes stream recovery
after an abnormal disconnect — see 9.1.

### 7. Connect / disconnect

```ts
const ok = await profile.connect();
await profile.disconnect();
```

`disconnect()` stops an active data notification first.

### 8. Device state

```ts
const state = profile.getDeviceState();   // DeviceState.DISCONNECTED .. INVALID
if (profile.isReady()) { }                // Ready: commands may be sent
const dev = profile.getDevice();          // BleDevice: name / mac / rssi
```

### 9. Auto reconnect and resume data stream

```ts
profile.setAutoReconnect(true);    // default on; set false to opt out
```

While enabled and the device is streaming, an abnormal disconnect is followed
by automatic reconnect -> `init()` with the previous arguments -> re-applying
the previous `setParam` values -> `startDataNotification()`. Explicit user
calls (`connect()`, `disconnect()`, `stopDataNotification()`) cancel a
pending resume.

To customize recovery, answer `true` from
`onAutoReconnect(profile, hasLastSession, answer)` and handle it yourself
(the answer may be given asynchronously); `false` falls back to the default
flow. If no answer arrives within 10 s the SDK runs the default recovery.

### 10. Device info

```ts
const info = profile.getDeviceInfo();   // valid after Ready + successful init
// deviceName, modelName, hardwareVersion, firmwareVersion, mtuSize,
// plus a channelCount / sampleRate pair per modality:
// emg/eeg/ecg/brth/acc/gyro/magAngle/euler/quat/ppg/spo2/impe, the
// aggregated imuChannelCount / imuSampleRate (0 = no aggregated stream),
// and emg/eeg/ecgMaxSampleRate (0 = not reported).
```

`fetchDeviceInfo(timeoutMs)` re-queries the device;
`setOnDeviceInfoUpdateListener` reports later changes.

### 11. Init data transfer

```ts
const ok = await profile.init(15, 60000, 30000);
// init(packageSampleCount, powerRefreshIntervalMs, timeoutMs)
const inited = profile.hasInited();
```

- `packageSampleCount`: samples per channel in each `SensorData` batch
  delivered to `onData`.
- `powerRefreshIntervalMs`: push period for `onPowerChanged` (0 = off).

### 12. Data notification

```ts
const ok = await profile.startDataNotification();
const streaming = profile.isDataTransfering();
await profile.stopDataNotification();
```

Data type list (`DataType`):

```
NTF_ACC = 1            acceleration, unit g
NTF_GYRO = 2           gyroscope, unit degree/s
NTF_EULER = 4          euler angle, unit degree
NTF_QUATERNION = 5     quaternion (w, x, y, z)
NTF_GEST = 7           gesture id
NTF_EMG = 8            unit uV
NTF_MAG_ANGLE = 13
NTF_EEG = 16           unit uV
NTF_ECG = 17           unit uV
NTF_IMPEDANCE = 18     electrode impedance
NTF_IMU = 19           aggregated IMU batch (acc 0-2 / gyro 3-5 / euler 6-8 /
                       quat 9-12; see DeviceInfo.imuChannelCount)
NTF_ADS = 20
NTF_BRTH = 21          respiration, unit uV
NTF_IMPEDANCE_EXT = 22
NTF_SPO2 = 23          SpO2 percentage
NTF_PPG = 24           PPG raw samples
```

Process data in `onData`. Each `SensorData` batch offers:

- metadata (all methods): `getDeviceMac()` / `getDataType()` /
  `getSampleRate()` / `getChannelCount()` / `getSampleCount()` /
  `getChannelMask()` / `isChannelEnabled(ch)` / `getLostPackageCount()` /
  `getStartTimeStamp()` / `getStartTimeSec()` / `getDelay()` /
  `isDataValid()`
- per-point accessors (`channel`, `index`): `getData` / `getRawData` /
  `getImpedance` / `getSaturation` / `getSampleIndex` / `getTimeStampInMs` /
  `getAbsTimeStampInSec` / `isLost`
- `clone()` for an owned deep copy; a borrowed batch is only guaranteed
  readable inside the callback — `clone()` whatever you keep.

### 12.1 Offload data handling to a worker thread

`useWorker(worker, listener)` moves data delivery off the main thread onto
a `@ohos.worker` thread: while a worker is attached, the main-thread
`onData` listener does not fire and the listener passed here is invoked on
the worker thread instead (the demo's `DspWorker` uses this for FFT
spectrum compute):

```ts
// called from inside the worker script: the first argument is the
// ThreadWorkerGlobalScope obtained there as worker.workerPort
profile.useWorker(worker.workerPort, (p, dataList) => {
  // runs on the worker thread
});

// stop the worker delivery (a null argument on either position detaches)
profile.useWorker(null);
```

Only one worker can be attached at a time; attaching a different worker
replaces the previous one.

### 13. Battery level

```ts
const power = await profile.getBatteryLevel();   // 0-100; issues a GATT read,
                                                 // -1 when the read fails
const cached = profile.getCachedPower();         // last reading, -1 = none yet
```

### 14. setParam / getParam

`setParam(key, value)` configures the profile after `Ready` + `init` and
resolves with `"OK"` on success or a string starting with `"Error"`.
Changing an `NTF_*` key while streaming restarts the data notification so
the setting takes effect; `FILTER_*` keys are applied on the fly without
interrupting the stream.

```ts
// Data stream toggles, "ON" / "OFF"
await profile.setParam('NTF_EEG', 'ON');
await profile.setParam('NTF_ECG', 'ON');
await profile.setParam('NTF_EMG', 'ON');
await profile.setParam('NTF_GEST', 'ON');    // NTF_GEST and NTF_EMG are mutually
                                             // exclusive on legacy EMG devices
await profile.setParam('NTF_BRTH', 'ON');
await profile.setParam('NTF_IMPEDANCE', 'ON');
await profile.setParam('NTF_MAG_ANGLE', 'ON');
await profile.setParam('NTF_PPG', 'ON');
await profile.setParam('NTF_SPO2', 'ON');
await profile.setParam('NTF_IMU', 'ON');     // master switch of the four
                                             // NTF_GFORCE_{ACC,GYRO,EULER,QUAT} streams

// Firmware filter toggles
await profile.setParam('FILTER_50HZ', 'ON');  // 50 Hz notch
await profile.setParam('FILTER_60HZ', 'ON');  // 60 Hz notch
await profile.setParam('FILTER_HPF', 'ON');   // 0.5 Hz high-pass
await profile.setParam('FILTER_LPF', 'ON');   // 80 Hz low-pass

// EEG/ECG sample rate (bound together on devices that have both); validated
// against getParam('EEG_SAMPLE_RATE_LIST')
await profile.setParam('EEG_SAMPLE_RATE', '500');

// EMG sample rate (new EMG devices only); validated against
// getParam('EMG_SAMPLE_RATE_LIST')
await profile.setParam('EMG_SAMPLE_RATE', '1000');

// IMU sample rate (devices answering the IMU cap query only); validated
// against getParam('IMU_SAMPLE_RATE_LIST')
await profile.setParam('IMU_SAMPLE_RATE', '100');

// PPG sample rate (PPG devices only); validated against
// getParam('PPG_SAMPLE_RATE_LIST')
await profile.setParam('PPG_SAMPLE_RATE', '200');

// Bin export: "True" exports the session capture on stop/disconnect into
// the SDK log directory; an absolute path exports there; "False"/"" disables.
// Once set, the capture is written directly at that path (visible while
// streaming); without a path it is copied there on stop/disconnect
await profile.setParam('DEBUG_BLE_DATA_PATH', 'True');

// Per-profile log file in the SDK log directory ("True"), or an absolute
// custom path; "False"/"" disables
await profile.setParam('DEBUG_LOG_PATH', 'True');

// Flush this device's pending bin capture and SDK log to disk; the value
// is ignored
await profile.setParam('FLUSH_BLE_DATA', '');
```

Aggregate queries via `getParam(key)`:

```ts
await profile.getParam('FILTER');               // "FILTER_50HZ|ON|FILTER_60HZ|ON|..."
await profile.getParam('NTF');                  // "NTF_BRTH|ON|NTF_ECG|ON|..."
await profile.getParam('EEG_SAMPLE_RATE');      // e.g. "250"
await profile.getParam('EEG_SAMPLE_RATE_LIST'); // e.g. "250|500"
await profile.getParam('EMG_SAMPLE_RATE');
await profile.getParam('EMG_SAMPLE_RATE_LIST');
await profile.getParam('IMU_SAMPLE_RATE');
await profile.getParam('IMU_SAMPLE_RATE_LIST');
await profile.getParam('PPG_SAMPLE_RATE');
await profile.getParam('PPG_SAMPLE_RATE_LIST');
```

## Bin file recording and replay

Every session's raw BLE capture can be exported as a `.bin` file (see
`DEBUG_BLE_DATA_PATH`) and replayed offline through the normal parsing
pipeline; parsed results arrive via `onData`, same as live data.

```ts
const info = await controller.getBinFileInfo(path);   // BinFileInfo: mac,
                                                      // deviceName, durationSec,
                                                      // deviceInfo, valid

// Replay (refused while the live device is linked: Connected or Ready)
const replay = await controller.replayBinFile(path, info.mac, true, 5000);
// resolves to the replay SensorProfile (null on failure); the mac is
// required — read it from the bin info first, as above

await controller.pauseBinReplay(mac);     // "OK" or an error string
await controller.resumeBinReplay(mac);
await controller.stopBinReplay(mac);

// Synchronized group replay: every (path, mac) capture starts on one shared
// clock anchored at the earliest data record, so concurrently recorded
// captures keep their original relative offsets. The returned mac list is
// input-order aligned minus the members that failed validation.
const started = await controller.multiReplayBinFile(
  [path1, path2], [sensor1, sensor2], true, 5000);
// parallel arrays of paths and SensorProfile objects; each member's target
// mac is read from its profile

// Offline conversion to CSV; resolves to the CSV file path
const csvPath = await controller.parseBinToCsv(binPath, csvPath);
```

## Logging controls

```ts
await controller.setParam('DEBUG_ENABLED', 'True');   // opens the controller log
await controller.setParam('LOG_PATH', dir);           // redirect; dir is created
await controller.setParam('LOG_PATH', 'True');        // back to the default
await controller.setParam('LOG_PATH', 'False');       // file output off
await controller.setParam('DATA_LOG_ENABLED', 'True'); // raw data records on
```

Ordering: `LOG_PATH` before `DEBUG_ENABLED=True`, and both before
`setBridge`, so the whole session lands in one directory.

Applications can write their own entries into the same timeline:

```ts
controller.log('User clicked start', 'I');    // controller log
profile.log('User toggled filter 50Hz', 'I'); // profile log when enabled
```

`level` accepts `"D"` / `"I"` / `"W"` / `"E"`; `"D"` follows the
`DEBUG_ENABLED` switch, the others are always emitted. Entries are tagged
`[App]`.

## Demo app

The bundled app exercises the whole API: multi-device scan/connect with
per-device state, two tabs (Device / Bio), bio waveforms with impedance
side texts, a magnetic-angle row and per-channel FFT spectra computed on a
worker thread (`useWorker`), IMU waveforms with FFT spectra and a 3D
quaternion cube, NTF/FILTER/sample-rate controls, battery display, auto
reconnect, SDK debug log and bin export toggles, a Translate IMU toggle
(split ACC/GYRO/EULER/QUAT streams vs the aggregated NTF_IMU stream), and
bin replay / parse-to-CSV. A Multi Start/Stop toggle starts (or stops)
streaming on all connected devices in sync via
`multiStartDataNotification` / `multiStopDataNotification`, and a Multi
Replay Bin button replays several captures at once through
`multiReplayBinFile` with group-wide pause/resume. The Replay Bin button
opens a browser of the SDK log directory (`sensorsdklog` under the app
files dir): pick a `.bin` to replay it, or export/pack a session directory
out of the sandbox. Replay end-of-file is reported through
`setOnDataTransferStateChangeListener` (isTransferring flips to false).

Build in DevEco Studio, or from the command line (run `ohpm install` in
`entry/` first; device signing is configured in the IDE — the project
ships without signing configs, so the command-line build emits an unsigned
hap):

```sh
cd entry && ohpm install && cd ..
hvigorw assembleHap --no-daemon
```

## License

MIT
