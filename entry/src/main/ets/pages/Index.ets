import { worker, MessageEvents, ErrorEvent } from '@kit.ArkTS';
import { SensorController, SensorProfile, SensorData, SensorAlgo, BleDevice, DeviceInfo,
  DeviceState, DataType, deviceStateName, dataTypeName, MultiDeviceResult } from 'sensor';
import { DeviceUiState } from './DeviceUiState';
import { LogBrowser } from './LogBrowser';
import { RingBuffer } from './RingBuffer';
import { drawWaveform, drawSpectrum } from './PlotRenderer';
import { drawCube } from './QuaternionCube';
import { LiveFilter } from '../dsp/LiveFilter';
import { computeSpectrum, SpectrumResult } from '../dsp/SpectrumCompute';
import fs from '@ohos.file.fs';

const DEMO_VERSION: string = '0.2.27';
const SCAN_PERIOD_MS: number = 5000;
const OP_TIMEOUT_MS: number = 0;
const BATTERY_REFRESH_MS: number = 60000;
const EVICT_MISSED_ROUNDS: number = 3;
const MAX_BIO_ROWS: number = 8;
const DATA_QUEUE_CAPACITY: number = 1000;
const ROW_HEIGHT: number = 110;
const CUBE_HEIGHT: number = 200;
const SPECTRUM_INTERVAL_MS: number = 200;
const RELAX_PLOT_TYPE: number = -1;

const NTF_KEYS: string[] = ['NTF_EEG', 'NTF_IMPEDANCE', 'NTF_EMG', 'NTF_GEST', 'NTF_PPG', 'NTF_SPO2',
  'NTF_IMU', 'NTF_MAG_ANGLE'];
const NTF_LABELS: string[] = ['EEG', 'IMPE', 'EMG', 'GESTURE', 'PPG', 'SpO2', 'IMU', 'Angle'];
const FILTER_KEYS: string[] = ['FILTER_50HZ', 'FILTER_60HZ', 'FILTER_HPF', 'FILTER_LPF'];
const FILTER_LABELS: string[] = ['50Hz', '60Hz', 'HPF', 'LPF'];

interface BioPlot {
  title: string;
  type: number;
  channel: number;
  spectrum: boolean;
  range: number[];
  impedance: boolean;
}

interface RateLabel {
  type: number;
  label: string;
}

interface ImuStreamDef {
  type: number;
  label: string;
  labels: string[];
  range: number[];
}

interface RateDef {
  key: string;
  label: string;
  candidates: number[];
}

const RATE_LABEL_ORDER: RateLabel[] = [
  { type: DataType.NTF_EEG, label: 'EEG' },
  { type: DataType.NTF_ECG, label: 'ECG' },
  { type: DataType.NTF_EMG, label: 'EMG' },
  { type: DataType.NTF_BRTH, label: 'BRTH' },
  { type: DataType.NTF_PPG, label: 'PPG' },
  { type: DataType.NTF_SPO2, label: 'SPO2' },
  { type: DataType.NTF_IMU, label: 'IMU' },
  { type: DataType.NTF_ACC, label: 'ACC' },
  { type: DataType.NTF_GYRO, label: 'GYRO' },
  { type: DataType.NTF_EULER, label: 'EULER' },
  { type: DataType.NTF_QUATERNION, label: 'QUAT' },
  { type: DataType.NTF_MAG_ANGLE, label: 'Angle' }
];

const BIO_TYPES: Set<number> = new Set<number>([
  DataType.NTF_EMG, DataType.NTF_EEG, DataType.NTF_ECG, DataType.NTF_BRTH
]);

const LIVE_FILTER_TYPES: Set<number> = new Set<number>([
  DataType.NTF_EMG, DataType.NTF_EEG, DataType.NTF_ECG, DataType.NTF_BRTH,
  DataType.NTF_PPG, DataType.NTF_SPO2
]);

const IMU_STREAMS: ImuStreamDef[] = [
  { type: DataType.NTF_ACC, label: 'ACC', labels: ['ACC-X', 'ACC-Y', 'ACC-Z'], range: [-8, 8] },
  { type: DataType.NTF_GYRO, label: 'GYRO', labels: ['GYRO-X', 'GYRO-Y', 'GYRO-Z'],
    range: [-2000, 2000] },
  { type: DataType.NTF_EULER, label: 'EULER', labels: ['Pitch(Y)', 'Roll(X)', 'Yaw(Z)'],
    range: [-180, 180] },
  { type: DataType.NTF_QUATERNION, label: 'QUAT', labels: ['W', 'X', 'Y', 'Z'], range: [-1, 1] }
];

const RATE_DEFS: RateDef[] = [
  { key: 'EEG_SAMPLE_RATE', label: 'EEG', candidates: [250, 500, 1000, 2000] },
  { key: 'EMG_SAMPLE_RATE', label: 'EMG', candidates: [500, 1000] },
  { key: 'IMU_SAMPLE_RATE', label: 'IMU', candidates: [50, 100, 200, 250, 400, 500, 1000, 2000] },
  { key: 'PPG_SAMPLE_RATE', label: 'PPG', candidates: [50, 100, 200, 400, 800, 1000, 1600, 3200] }
];

class DeviceRow {
  name: string = '';
  mac: string = '';
  rssi: number = 0;
  missedRounds: number = 0;
  connected: boolean = false;
  streaming: boolean = false;
  replay: boolean = false;
}

class RateGroup {
  key: string = '';
  label: string = '';
  usable: number[] = [];
  current: number = 0;
}

class NtfItem {
  key: string = '';
  label: string = '';
  checked: boolean = false;
  visible: boolean = true;
}

class FilterItem {
  key: string = '';
  label: string = '';
  checked: boolean = false;
}

interface QueuedBatch {
  st: DeviceUiState;
  data: SensorData;
}

interface DspStatsPayload {
  batches: number;
  samples: number;
  rateSamples: Record<string, number>;
  rateTags: Record<string, number>;
  lostCounts: Record<string, number>;
  counters: Record<string, number>;
  expectedRates: Record<string, number>;
  startTimeSecs: Record<string, number>;
  delayMs: number;
  impedance: Record<string, number>;
  gestureSeen: boolean;
  gesture: number;
  rawGesture: number;
  possibility: number;
  strength: number;
}

interface DspFrame {
  kind: string;
  waves: Record<string, Float32Array[]>;
  specs: Record<string, SpectrumResult | null>;
  stats: DspStatsPayload;
}

function isErrorResult(s: string): boolean {
  return s.toLowerCase().indexOf('error') === 0;
}

function pad2(v: number): string {
  return v < 10 ? '0' + v.toString() : v.toString();
}

function pad3(v: number): string {
  let s: string = v.toString();
  while (s.length < 3) {
    s = '0' + s;
  }
  return s;
}

@Entry
@Component
struct Index {
  @State demoTitle: string = 'SensorEtsDemo v' + DEMO_VERSION;
  @State scanning: boolean = false;
  @State devices: DeviceRow[] = [];
  @State currentMac: string = '';
  @State currentTab: number = 0;
  @State statusLine: string = 'No device selected';
  @State messageLine: string = '';
  @State batteryLine: string = 'Battery: -';
  @State countersLine: string = 'No data yet';
  @State rateLine: string = 'Actual: --';
  @State lostLine: string = 'Packet Loss: --';
  @State linkLine: string = 'Link: --';
  @State infoLine1: string = 'Model: -- | HW: --';
  @State infoLine2: string = 'FW: -- | MTU: --';
  @State streamLine: string = '';
  @State errorLine: string = '';
  @State multiLine: string = '';
  @State switchesEnabled: boolean = false;
  @State filterSupported: boolean = true;
  @State ntfItems: NtfItem[] = [];
  @State filterItems: FilterItem[] = [];
  @State rateGroups: RateGroup[] = [];
  @State autoReconnect: boolean = true;
  @State cloneData: boolean = false;
  @State useWorklets: boolean = true;
  @State debugLogEnabled: boolean = true;
  @State binDataEnabled: boolean = true;
  @State translateImu: boolean = false;
  @State showLogBrowser: boolean = false;
  @State binPath: string = '';
  @State binInfoLine: string = '';
  @State replayPaused: boolean = false;
  @State replayActive: boolean = false;
  @State liveFilterBand: number = 0;
  @State bioPages: number = 1;
  @State eegPageView: number = 0;
  @State bioCanvasHeight: number = ROW_HEIGHT;
  @State imuCanvasHeight: number = CUBE_HEIGHT + 4 * ROW_HEIGHT;
  @State imuValues: string = '--';
  @State gestureLines: string[] = [
    'gesture (0-8): -', 'raw gesture (0-8): -', 'possiblity (0-100): -', 'strength (0-100): -'
  ];

  private controller: SensorController = SensorController.getInstance();
  private states: Map<string, DeviceUiState> = new Map<string, DeviceUiState>();
  private replayMacs: Set<string> = new Set<string>();
  private replayStopRequested: Set<string> = new Set<string>();
  private paramHistory: Map<string, Map<string, string>> = new Map<string, Map<string, string>>();
  private lastLogPaths: Map<string, string> = new Map<string, string>();
  private lastDataPaths: Map<string, string> = new Map<string, string>();
  private bandLabels: string[] = LiveFilter.bandLabels();
  private backendName: string = '';
  private rateRotateIndex: number = 0;
  private bioCanvasReady: boolean = false;
  private imuCanvasReady: boolean = false;
  private bioSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private bioContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.bioSettings);
  private imuSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private imuContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.imuSettings);
  private plotTimer: number = -1;
  private statsTimer: number = -1;
  private relaxQueryPending: boolean = false;
  private dataQueue: QueuedBatch[] = [];
  private dspWorkers: Map<string, worker.ThreadWorker> = new Map<string, worker.ThreadWorker>();

  aboutToAppear(): void {
    this.refreshDemoTitle();
    this.refreshBackendName();
    this.binPath = getContext(this).filesDir + '/test.bin';
    this.resetParamItems();
    this.controller.setOnScanResultListener((devices: BleDevice[]): void => {
      this.mergeScanRound(devices);
    });
    this.plotTimer = setInterval((): void => {
      this.drainDataQueue();
      this.drawTick();
      this.refreshRelax();
    }, 50);
    this.statsTimer = setInterval((): void => {
      this.settleStats();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.plotTimer >= 0) {
      clearInterval(this.plotTimer);
      this.plotTimer = -1;
    }
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
    this.controller.setOnScanResultListener(null);
  }

  private resetParamItems(): void {
    const ntfs: NtfItem[] = [];
    for (let i = 0; i < NTF_KEYS.length; i++) {
      const item: NtfItem = new NtfItem();
      item.key = NTF_KEYS[i];
      item.label = NTF_LABELS[i];
      ntfs.push(item);
    }
    this.ntfItems = ntfs;
    const filters: FilterItem[] = [];
    for (let i = 0; i < FILTER_KEYS.length; i++) {
      const item: FilterItem = new FilterItem();
      item.key = FILTER_KEYS[i];
      item.label = FILTER_LABELS[i];
      filters.push(item);
    }
    this.filterItems = filters;
  }

  // ---- helpers ----

  private currentState(): DeviceUiState | null {
    if (this.currentMac.length === 0) {
      return null;
    }
    const st: DeviceUiState | undefined = this.states.get(this.currentMac);
    return st !== undefined ? st : null;
  }

  private currentProfile(): SensorProfile | null {
    const st: DeviceUiState | null = this.currentState();
    return st !== null ? st.profile : null;
  }

  private ensureState(mac: string, profile: SensorProfile): DeviceUiState {
    let st: DeviceUiState | undefined = this.states.get(mac);
    if (st === undefined) {
      st = new DeviceUiState();
      st.mac = mac;
      this.states.set(mac, st);
    }
    st.profile = profile;
    st.liveFilter.setBand(this.liveFilterBand);
    if (st.algo === null && !st.algoCreating) {
      st.recreateAlgo(this.cloneData);
    }
    return st;
  }

  private appLog(message: string, level: string = 'I', st?: DeviceUiState): void {
    const target: DeviceUiState | null = st !== undefined ? st : this.currentState();
    if (target !== null && target.profile !== null) {
      target.profile.log(message, level);
      return;
    }
    this.controller.log(message, level);
  }

  // ---- header backend label ----

  private refreshDemoTitle(): void {
    const backend: string = this.backendName.length > 0 ? ' | Backend: ' + this.backendName : '';
    this.demoTitle = 'SensorEtsDemo v' + DEMO_VERSION + ' | SDK ' + this.controller.getVersion() +
      ' | Algo ' + SensorAlgo.algoCapiVersion().toString() + backend;
  }

  private async refreshBackendName(): Promise<void> {
    try {
      const name: string = await this.controller.getParam('BACK_END');
      if (name.length > 0 && !name.startsWith('Error') && name !== this.backendName) {
        this.backendName = name;
        this.refreshDemoTitle();
      }
    } catch (err) {
    }
  }

  private isDisplayReady(st: DeviceUiState): boolean {
    if (st.profile !== null && st.profile.isReady()) {
      return true;
    }
    return st.isReplay && st.info !== null;
  }

  // ---- scan list ----

  private mergeScanRound(found: BleDevice[]): void {
    const seen: Set<string> = new Set<string>();
    for (const d of found) {
      seen.add(d.mac);
    }
    const kept: DeviceRow[] = [];
    for (const row of this.devices) {
      if (seen.has(row.mac)) {
        row.missedRounds = 0;
        kept.push(row);
      } else {
        row.missedRounds++;
        if (row.missedRounds < EVICT_MISSED_ROUNDS || row.connected || row.streaming ||
          row.replay) {
          kept.push(row);
        }
      }
    }
    for (const d of found) {
      let existing: DeviceRow | null = null;
      for (const row of kept) {
        if (row.mac === d.mac) {
          existing = row;
          break;
        }
      }
      if (existing !== null) {
        existing.rssi = d.rssi;
        if (d.name.length > 0) {
          existing.name = d.name;
        }
      } else {
        const row: DeviceRow = new DeviceRow();
        row.name = d.name;
        row.mac = d.mac;
        row.rssi = d.rssi;
        let idx: number = kept.length;
        for (let i = 0; i < kept.length; i++) {
          if (d.rssi > kept[i].rssi) {
            idx = i;
            break;
          }
        }
        kept.splice(idx, 0, row);
      }
    }
    this.devices = kept;
  }

  private rowTitle(row: DeviceRow): string {
    let title: string = row.name + ' [' + row.mac + ']';
    if (row.replay) {
      title += ' [Replay]';
    } else {
      title += ' rssi=' + row.rssi.toString();
    }
    if (row.connected) {
      title += ' [Connected]';
    }
    if (row.streaming) {
      title += ' [Streaming]';
    }
    return title;
  }

  private updateRowMarks(mac: string, connected: boolean, streaming: boolean): void {
    const rows: DeviceRow[] = this.devices.slice();
    for (const row of rows) {
      if (row.mac === mac) {
        row.connected = connected;
        row.streaming = streaming;
        break;
      }
    }
    this.devices = rows;
  }

  private addReplayRow(mac: string, name: string): void {
    const rows: DeviceRow[] = this.devices.filter((row: DeviceRow) => row.mac !== mac);
    const row: DeviceRow = new DeviceRow();
    row.name = name;
    row.mac = mac;
    row.replay = true;
    row.connected = true;
    row.streaming = true;
    rows.unshift(row);
    this.devices = rows;
  }

  private removeRow(mac: string): void {
    this.devices = this.devices.filter((row: DeviceRow) => row.mac !== mac);
  }

  private onScanStart(): void {
    this.appLog('User: start scan');
    this.scanning = this.controller.startScan(SCAN_PERIOD_MS);
    if (!this.scanning) {
      this.errorLine = 'startScan failed (Bluetooth off or permission missing)';
    }
  }

  private onScanStop(): void {
    this.appLog('User: stop scan');
    this.controller.stopScan();
    this.scanning = false;
  }

  // ---- current device ----

  private refreshStatus(): void {
    const p: SensorProfile | null = this.currentProfile();
    if (p === null) {
      this.statusLine = 'No device selected';
      this.switchesEnabled = false;
      return;
    }
    this.switchesEnabled = p.isReady();
    this.statusLine = 'state=' + deviceStateName(p.getDeviceState()) +
      ' hasInited=' + p.hasInited().toString() +
      ' isDataTransfering=' + p.isDataTransfering().toString();
  }

  private batteryText(st: DeviceUiState): string {
    return st.power >= 0 ? 'Battery: ' + st.power.toString() + '%' : 'Battery: -';
  }

  private streamSummary(info: DeviceInfo): string {
    const parts: string[] = [];
    const add = (label: string, ch: number, rate: number): void => {
      if (ch > 0) {
        parts.push(label + ' ' + ch.toString() + 'ch @ ' + rate.toString() + 'Hz');
      }
    };
    add('EEG', info.eegChannelCount, info.eegSampleRate);
    add('ECG', info.ecgChannelCount, info.ecgSampleRate);
    add('EMG', info.emgChannelCount, info.emgSampleRate);
    add('BRTH', info.brthChannelCount, info.brthSampleRate);
    add('PPG', info.ppgChannelCount, info.ppgSampleRate);
    add('SpO2', info.spo2ChannelCount, info.spo2SampleRate);
    add('ACC', info.accChannelCount, info.accSampleRate);
    add('GYRO', info.gyroChannelCount, info.gyroSampleRate);
    add('Angle', info.magAngleChannelCount, info.magAngleSampleRate);
    return parts.join(' | ');
  }

  private buildRateLine(st: DeviceUiState): string {
    const avail: RateLabel[] = [];
    for (const rl of RATE_LABEL_ORDER) {
      if (st.expectedRates.has(rl.type)) {
        avail.push(rl);
      }
    }
    if (avail.length === 0) {
      return 'Actual: --';
    }
    const rl: RateLabel = avail[this.rateRotateIndex % avail.length];
    const nominal: number = st.expectedRates.get(rl.type) ?? 0;
    const measured: number = st.actualRates.get(rl.type) ?? 0;
    let line: string = 'Actual: ' + rl.label + ' ' + measured.toFixed(1) + ' / ' +
      nominal.toString() + 'Hz';
    const startSec: number = st.streamStartTimeSecs.get(rl.type) ?? 0;
    if (startSec > 0) {
      const d: Date = new Date(startSec * 1000);
      line += ' | start ' + d.getFullYear().toString() + '-' + pad2(d.getMonth() + 1) + '-' +
        pad2(d.getDate()) + ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' +
        pad2(d.getSeconds()) + '.' + pad3(d.getMilliseconds());
    }
    if (st.streamDelayMs > 0) {
      line += ' | delay ' + st.streamDelayMs.toString() + 'ms';
    }
    return line;
  }

  private buildLostLine(st: DeviceUiState): string {
    const parts: string[] = [];
    for (const rl of RATE_LABEL_ORDER) {
      const lost: number | undefined = st.lostCounts.get(rl.type);
      if (lost !== undefined) {
        parts.push(rl.label + ' ' + lost.toString());
      }
    }
    return parts.length > 0 ? 'Packet Loss: ' + parts.join(' | ') : 'Packet Loss: --';
  }

  private refreshAllLines(): void {
    const st: DeviceUiState | null = this.currentState();
    if (st === null) {
      this.batteryLine = 'Battery: -';
      this.countersLine = 'No data yet';
      this.rateLine = 'Actual: --';
      this.lostLine = 'Packet Loss: --';
      this.linkLine = 'Link: --';
      this.infoLine1 = 'Model: -- | HW: --';
      this.infoLine2 = 'FW: -- | MTU: --';
      this.streamLine = '';
      this.eegPageView = 0;
      this.gestureLines = [
        'gesture (0-8): -', 'raw gesture (0-8): -', 'possiblity (0-100): -', 'strength (0-100): -'
      ];
      return;
    }
    this.batteryLine = this.batteryText(st);
    let counters: string = '';
    st.counters.forEach((count: number, name: string): void => {
      counters += (counters.length > 0 ? ' | ' : '') + name + ' ' + count.toString();
    });
    this.countersLine = counters.length > 0 ? counters : 'No data yet';
    this.rateLine = this.buildRateLine(st);
    this.lostLine = this.buildLostLine(st);
    const info: DeviceInfo | null = st.info;
    if (info !== null) {
      this.infoLine1 = 'Model: ' + (info.modelName.length > 0 ? info.modelName : '--') +
        ' | HW: ' + (info.hardwareVersion.length > 0 ? info.hardwareVersion : '--');
      this.infoLine2 = 'FW: ' + (info.firmwareVersion.length > 0 ? info.firmwareVersion : '--') +
        ' | MTU: ' + (info.mtuSize > 0 ? info.mtuSize.toString() : '--');
      const backend: string = info.backend.length > 0 ? ' | backend ' + info.backend : '';
      this.linkLine = info.peripheralLatency >= 0 && info.connectionIntervalMs > 0 ?
        'Link: ' + info.connectionIntervalMs.toString() + 'ms / latency ' +
        info.peripheralLatency.toString() + ' / timeout ' +
        info.supervisionTimeoutMs.toString() + 'ms' + backend :
        'Link: --' + backend;
      this.streamLine = this.streamSummary(info);
    } else {
      this.linkLine = 'Link: --';
      this.infoLine1 = 'Model: -- | HW: --';
      this.infoLine2 = 'FW: -- | MTU: --';
      this.streamLine = '';
    }
    this.eegPageView = st.eegPage;
    this.gestureLines = [
      'gesture (0-8): ' + (st.gestureSeen ? st.gesture.toString() : '-'),
      'raw gesture (0-8): ' + (st.gestureSeen ? st.rawGesture.toString() : '-'),
      'possiblity (0-100): ' + (st.gestureSeen ? st.possibility.toString() : '-'),
      'strength (0-100): ' + (st.gestureSeen ? st.strength.toString() : '-')
    ];
  }

  private selectDevice(mac: string): void {
    this.currentMac = mac;
    this.errorLine = '';
    this.refreshStatus();
    this.refreshAllLines();
    this.syncPanel();
  }

  // ---- profile listeners ----

  private attachProfileListeners(st: DeviceUiState): void {
    const profile: SensorProfile = st.profile as SensorProfile;
    profile.setOnStateChangeListener((p: SensorProfile, newState: number): void => {
      this.onProfileStateChange(st, p, newState);
    });
    profile.setOnPowerListener((p: SensorProfile, power: number): void => {
      st.applyPower(power);
      if (st.mac === this.currentMac) {
        this.batteryLine = this.batteryText(st);
      }
    });
    profile.setOnErrorListener((p: SensorProfile, errorMsg: string): void => {
      this.appLog('App: error callback: ' + errorMsg, 'E', st);
      if (st.mac === this.currentMac) {
        this.errorLine = 'Error: ' + errorMsg;
      }
    });
    profile.setOnDataListener((p: SensorProfile, dataList: SensorData[]): void => {
      this.onData(st, dataList);
    });
    profile.setOnDeviceInfoUpdateListener((p: SensorProfile, info: DeviceInfo): void => {
      st.info = info;
      if (st.mac === this.currentMac) {
        this.seedRateCurrent(info);
        this.refreshAllLines();
        this.refreshStatus();
      }
    });
    profile.setOnDataTransferStateChangeListener(
      (p: SensorProfile, isTransferring: boolean): void => {
        st.streaming = isTransferring;
        this.appLog('App: data stream ' + (isTransferring ? 'ON' : 'OFF') + ' ' + st.mac, 'I', st);
        if (isTransferring) {
          this.resetAlgo(st);
        }
        this.updateRowMarks(st.mac, p.isReady() || p.getDeviceState() === DeviceState.CONNECTED,
          isTransferring);
        if (st.isReplay && !isTransferring) {
          const stopRequested: boolean = this.replayStopRequested.delete(st.mac);
          const message: string = stopRequested ? 'Replay stopped' :
            'Replay finished (' + st.batches.toString() + ' batches, ' +
            st.totalSamples.toString() + ' samples)';
          this.appLog('App: replay done: ' + message, 'I', st);
          this.replayMacs.delete(st.mac);
          this.replayPaused = false;
          this.replayActive = this.replayMacs.size > 0;
          if (st.mac === this.currentMac) {
            this.messageLine = message;
          }
          return;
        }
        if (st.mac === this.currentMac) {
          this.refreshStatus();
        }
      });
    profile.setOnAutoReconnectListener(
      (p: SensorProfile, hasLastSession: boolean, answer: (takeover: boolean) => void): void => {
        if (!this.autoReconnect) {
          answer(false);
          return;
        }
        this.appLog('App: auto reconnect callback received, restore=' +
          (hasLastSession ? 'True' : 'False'), 'I', st);
        answer(true);
        this.recoverSession(st, hasLastSession);
      });
  }

  private onProfileStateChange(st: DeviceUiState, p: SensorProfile, newState: number): void {
    const connected: boolean = newState === DeviceState.CONNECTED || newState === DeviceState.READY;
    this.updateRowMarks(st.mac, connected, connected && p.isDataTransfering());
    if (newState === DeviceState.DISCONNECTED) {
      this.appLog('App: device disconnected, removed from UI: ' + st.mac);
      this.teardownState(st);
    }
    if (st.mac === this.currentMac) {
      this.refreshStatus();
      this.refreshAllLines();
    }
  }

  private teardownState(st: DeviceUiState): void {
    this.unbindWorklet(st);
    st.resetSession();
    this.dataQueue = this.dataQueue.filter((item: QueuedBatch): boolean => item.st !== st);
    if (st.isReplay) {
      st.discardAlgo();
      this.states.delete(st.mac);
      this.removeRow(st.mac);
    } else if (st.mac === this.currentMac) {
      this.syncPanel();
    }
  }

  // ---- connect / stream ----

  private hasLiveDevices(): boolean {
    let live: boolean = false;
    this.states.forEach((st: DeviceUiState): void => {
      if (st.isReplay || st.profile === null) {
        return;
      }
      const s: number = st.profile.getDeviceState();
      if (s === DeviceState.CONNECTED || s === DeviceState.READY || s === DeviceState.CONNECTING) {
        live = true;
      }
    });
    return live;
  }

  private async onConnect(): Promise<void> {
    const mac: string = this.currentMac;
    if (mac.length === 0) {
      return;
    }
    if (this.replayMacs.size > 0) {
      this.errorLine = 'connect rejected: a replay session is running';
      return;
    }
    const existing: SensorProfile | null = this.currentProfile();
    if (existing !== null && existing.getDeviceState() !== DeviceState.DISCONNECTED) {
      const st0: DeviceUiState | null = this.currentState();
      if (st0 !== null) {
        await this.runReadyChain(st0, false);
      }
      return;
    }
    if (this.scanning) {
      this.controller.stopScan();
      this.scanning = false;
    }
    this.appLog('User: connect ' + mac);
    const profile: SensorProfile | null = this.controller.requireSensor(mac);
    if (profile === null) {
      this.errorLine = 'requireSensor failed for ' + mac;
      return;
    }
    const st: DeviceUiState = this.ensureState(mac, profile);
    st.isReplay = false;
    this.attachProfileListeners(st);
    profile.autoReconnect = this.autoReconnect;
    this.errorLine = '';
    const ok: boolean = await profile.connect();
    if (!ok) {
      this.appLog('App: connect failed ' + mac, 'E', st);
      this.errorLine = 'connect failed (see SDK log)';
      this.refreshStatus();
      return;
    }
    await this.runReadyChain(st, false);
  }

  private async onDisconnect(): Promise<void> {
    const st: DeviceUiState | null = this.currentState();
    if (st === null || st.profile === null) {
      return;
    }
    this.appLog('User: disconnect ' + st.mac);
    await st.profile.disconnect();
    this.refreshStatus();
  }

  private async runReadyChain(st: DeviceUiState, restoreParams: boolean): Promise<void> {
    if (st.flowRunning || st.profile === null) {
      return;
    }
    const p: SensorProfile = st.profile;
    if (st.flowStarted && p.hasInited()) {
      this.refreshStatus();
      return;
    }
    st.flowRunning = true;
    try {
      if (!p.hasInited()) {
        const ok: boolean = await p.init(32, BATTERY_REFRESH_MS, OP_TIMEOUT_MS);
        if (!ok) {
          this.appLog('App: failed to initialize ' + st.mac, 'E', st);
          this.errorLine = 'init failed (see SDK log)';
          return;
        }
      }
      const info: DeviceInfo | null = await p.fetchDeviceInfo(OP_TIMEOUT_MS);
      if (info !== null) {
        st.info = info;
        this.seedRateCurrent(info);
      }
      if (!p.isDataTransfering()) {
        const started: boolean = await p.startDataNotification(OP_TIMEOUT_MS);
        if (!started) {
          this.appLog('App: failed to start data stream on ' + st.mac, 'E', st);
          this.errorLine = 'start stream failed (see SDK log)';
          return;
        }
        this.appLog('App: device connected and streaming: ' + st.mac, 'I', st);
      }
      if (this.debugLogEnabled) {
        const logPath: string = this.lastLogPaths.get(st.mac) ?? 'True';
        await p.setParam('DEBUG_LOG_PATH', logPath);
        const currentLog: string = await p.getParam('DEBUG_LOG_PATH');
        if (currentLog.length > 0 && !isErrorResult(currentLog)) {
          this.lastLogPaths.set(st.mac, currentLog);
          this.openAlgoCsv(st, currentLog);
        }
      }
      if (this.binDataEnabled) {
        const dataPath: string = this.lastDataPaths.get(st.mac) ?? 'True';
        await p.setParam('DEBUG_BLE_DATA_PATH', dataPath);
        const currentData: string = await p.getParam('DEBUG_BLE_DATA_PATH');
        if (currentData.length > 0 && !isErrorResult(currentData)) {
          this.lastDataPaths.set(st.mac, currentData);
        }
      }
      if (restoreParams) {
        const history: Map<string, string> | undefined = this.paramHistory.get(st.mac);
        if (history !== undefined) {
          for (const entry of Array.from(history.entries())) {
            const result: string = await p.setParam(entry[0], entry[1]);
            this.appLog('App: restore setParam(' + entry[0] + ', ' + entry[1] + ') -> ' + result,
              'I', st);
          }
        }
      }
      const power: number = await p.getBatteryLevel();
      if (power >= 0) {
        st.applyPower(power);
      }
      st.flowStarted = true;
      if (this.useWorklets) {
        this.ensureWorkletBinding(st);
      }
      if (st.mac === this.currentMac) {
        this.errorLine = '';
        this.refreshStatus();
        this.refreshAllLines();
        this.syncPanel();
      }
    } finally {
      st.flowRunning = false;
    }
  }

  private async onBatteryRead(): Promise<void> {
    const st: DeviceUiState | null = this.currentState();
    if (st === null || st.profile === null) {
      return;
    }
    const v: number = await st.profile.getBatteryLevel();
    this.appLog('User: battery query -> ' + v.toString(), 'I', st);
    st.power = v >= 0 ? v : -1;
    this.batteryLine = this.batteryText(st);
  }

  private async recoverSession(st: DeviceUiState, hasLastSession: boolean): Promise<void> {
    const p: SensorProfile = st.profile as SensorProfile;
    this.currentMac = st.mac;
    const connected: boolean = await p.connect();
    if (!connected) {
      return;
    }
    await this.runReadyChain(st, hasLastSession);
  }

  private recordParam(mac: string, key: string, value: string): void {
    let history: Map<string, string> | undefined = this.paramHistory.get(mac);
    if (history === undefined) {
      history = new Map<string, string>();
      this.paramHistory.set(mac, history);
    }
    history.set(key, value);
  }

  private multiTargets(): SensorProfile[] {
    const targets: SensorProfile[] = [];
    this.states.forEach((st: DeviceUiState): void => {
      if (!st.isReplay && st.profile !== null && st.profile.isReady() && st.profile.hasInited()) {
        targets.push(st.profile as SensorProfile);
      }
    });
    return targets;
  }

  private async onMultiStop(): Promise<void> {
    const targets: SensorProfile[] = this.multiTargets();
    if (targets.length === 0) {
      this.multiLine = 'Multi: no ready device';
      return;
    }
    this.appLog('User: multi stop on ' + targets.length.toString() + ' device(s)');
    const results: MultiDeviceResult[] =
      await this.controller.multiStopDataNotification(targets, 10000);
    this.reportMultiResult('stop', 'stopped', results);
    this.refreshStatus();
  }

  private async onMultiStart(): Promise<void> {
    const targets: SensorProfile[] = this.multiTargets();
    if (targets.length === 0) {
      this.multiLine = 'Multi: no ready device';
      return;
    }
    this.appLog('User: multi start on ' + targets.length.toString() + ' device(s)');
    const streaming: SensorProfile[] = targets.filter((p: SensorProfile) => p.isDataTransfering());
    if (streaming.length > 0) {
      const stopResults: MultiDeviceResult[] =
        await this.controller.multiStopDataNotification(streaming, 10000);
      const stopFailed: MultiDeviceResult[] = stopResults.filter((r: MultiDeviceResult) => !r.ok);
      if (stopFailed.length > 0) {
        this.multiLine = 'Multi stop failed on: ' +
          stopFailed.map((r: MultiDeviceResult) => r.mac).join(', ');
        return;
      }
    }
    const results: MultiDeviceResult[] =
      await this.controller.multiStartDataNotification(targets);
    this.reportMultiResult('start', 'started', results);
    this.refreshStatus();
  }

  private reportMultiResult(action: string, past: string, results: MultiDeviceResult[]): void {
    const failed: MultiDeviceResult[] = results.filter((r: MultiDeviceResult) => !r.ok);
    for (const r of failed) {
      const st: DeviceUiState | undefined = this.states.get(r.mac);
      this.appLog('App: multi ' + action + ' failed[' + r.mac + ']: ' + r.error, 'W', st);
    }
    if (failed.length === 0) {
      this.appLog('App: multi ' + action + ' OK: ' + results.length.toString() + ' device(s) ' +
        past);
    }
    const parts: string[] = results.map((r: MultiDeviceResult) =>
      r.mac + ' ' + (r.ok ? 'OK' : r.error));
    this.multiLine = 'Multi ' + action + ': ' + parts.join(' | ');
  }

  private onAutoReconnectToggle(isOn: boolean): void {
    this.appLog('User: auto reconnect ' + (isOn ? 'ON' : 'OFF'));
    this.autoReconnect = isOn;
    this.states.forEach((st: DeviceUiState): void => {
      if (st.profile !== null) {
        st.profile.autoReconnect = isOn;
      }
    });
  }

  // ---- debug toggles ----

  private sessionLogDir(): string {
    const d: Date = new Date();
    const ts: string = d.getFullYear().toString() + pad2(d.getMonth() + 1) + pad2(d.getDate()) +
      '_' + pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds());
    return getContext(this).filesDir + '/sensorsdklog/' + ts + '_' +
      this.controller.getVersion().replace(/\./g, '_');
  }

  private async onDebugLogToggle(enabled: boolean): Promise<void> {
    this.appLog('User: SDK debug log ' + (enabled ? 'ON' : 'OFF'));
    this.debugLogEnabled = enabled;
    if (enabled) {
      await this.controller.setParam('LOG_PATH', this.sessionLogDir());
    } else {
      await this.controller.setParam('LOG_PATH', 'False');
    }
    await this.controller.setParam('DEBUG_ENABLED', enabled ? 'True' : 'False');
    const value: string = enabled ? 'True' : 'False';
    this.states.forEach((st: DeviceUiState): void => {
      if (st.profile !== null && st.profile.isReady() && st.profile.hasInited()) {
        st.profile.setParam('DEBUG_LOG_PATH', value).then((result: string): void => {
          if (st.profile !== null) {
            st.profile.log('App: setParam(DEBUG_LOG_PATH, ' + value + ') -> ' + result, 'I');
          }
        });
      }
    });
  }

  private onBinDataToggle(enabled: boolean): void {
    this.appLog('User: data debug log ' + (enabled ? 'ON' : 'OFF'));
    this.binDataEnabled = enabled;
    const value: string = enabled ? 'True' : 'False';
    this.states.forEach((st: DeviceUiState): void => {
      if (st.profile !== null && st.profile.isReady() && st.profile.hasInited()) {
        st.profile.setParam('DEBUG_BLE_DATA_PATH', value).then((result: string): void => {
          if (st.profile !== null) {
            st.profile.log('App: setParam(DEBUG_BLE_DATA_PATH, ' + value + ') -> ' + result, 'I');
          }
        });
      }
    });
  }

  private onTranslateImuToggle(enabled: boolean): void {
    this.appLog('User: translate IMU ' + (enabled ? 'ON' : 'OFF'));
    this.translateImu = enabled;
    const value: string = enabled ? 'True' : 'False';
    this.controller.setParam('TRANSLATE_IMU', value).then((result: string): void => {
      this.appLog('App: setParam(TRANSLATE_IMU, ' + value + ') -> ' + result);
    });
  }

  // ---- NTF / FILTER switches ----

  private ntfValue(aggregate: string, key: string): boolean {
    const parts: string[] = aggregate.split('|');
    for (let i = 0; i + 1 < parts.length; i += 2) {
      if (parts[i] === key) {
        return parts[i + 1] === 'ON';
      }
    }
    return false;
  }

  private ntfChannelCount(key: string, info: DeviceInfo): number {
    switch (key) {
      case 'NTF_EEG':
        return info.eegChannelCount;
      case 'NTF_IMPEDANCE':
        return info.impeChannelCount;
      case 'NTF_EMG':
      case 'NTF_GEST':
        return info.emgChannelCount;
      case 'NTF_PPG':
        return info.ppgChannelCount;
      case 'NTF_SPO2':
        return info.spo2ChannelCount;
      case 'NTF_IMU':
        return info.accChannelCount + info.gyroChannelCount;
      case 'NTF_MAG_ANGLE':
        return info.magAngleChannelCount;
      default:
        return 0;
    }
  }

  private syncPanel(): void {
    this.syncNtfSwitches();
    this.syncFilterSwitches();
    this.syncRateGroups();
  }

  private async syncNtfSwitches(): Promise<void> {
    const st: DeviceUiState | null = this.currentState();
    if (st === null || st.profile === null) {
      return;
    }
    const result: string = await st.profile.getParam('NTF');
    if (isErrorResult(result)) {
      return;
    }
    const items: NtfItem[] = [];
    for (let i = 0; i < NTF_KEYS.length; i++) {
      const item: NtfItem = new NtfItem();
      item.key = NTF_KEYS[i];
      item.label = NTF_LABELS[i];
      item.checked = this.ntfValue(result, item.key);
      item.visible = st.info === null || this.ntfChannelCount(item.key, st.info) > 0;
      if (!item.visible) {
        item.checked = false;
      }
      items.push(item);
    }
    st.impedanceEnabled = st.info !== null && st.info.impeChannelCount > 0 &&
      this.ntfValue(result, 'NTF_IMPEDANCE');
    this.ntfItems = items;
  }

  private async syncFilterSwitches(): Promise<void> {
    const st: DeviceUiState | null = this.currentState();
    if (st === null || st.profile === null) {
      return;
    }
    const result: string = await st.profile.getParam('FILTER');
    if (isErrorResult(result)) {
      this.filterSupported = false;
      return;
    }
    this.filterSupported = true;
    const items: FilterItem[] = [];
    for (let i = 0; i < FILTER_KEYS.length; i++) {
      const item: FilterItem = new FilterItem();
      item.key = FILTER_KEYS[i];
      item.label = FILTER_LABELS[i];
      item.checked = this.ntfValue(result, item.key);
      items.push(item);
    }
    this.filterItems = items;
  }

  private clearBuffers(st: DeviceUiState): void {
    st.buffers.forEach((buf: RingBuffer): void => {
      buf.clear();
    });
    st.impedance.clear();
    const w: worker.ThreadWorker | undefined = this.dspWorkers.get(st.mac);
    if (w !== undefined) {
      w.postMessage({ kind: 'clear', band: 0 });
    }
  }

  private async onParamToggle(key: string, isOn: boolean, isFilter: boolean): Promise<void> {
    const st: DeviceUiState | null = this.currentState();
    if (st === null || st.profile === null) {
      this.syncPanel();
      return;
    }
    const value: string = isOn ? 'ON' : 'OFF';
    const result: string = await st.profile.setParam(key, value);
    this.appLog('User: setParam(' + key + ', ' + value + ') -> ' + result, 'I', st);
    if (isErrorResult(result)) {
      this.errorLine = 'setParam ' + key + ' failed: ' + result;
    } else {
      this.errorLine = '';
      this.recordParam(st.mac, key, value);
      this.clearBuffers(st);
    }
    if (isFilter) {
      this.syncFilterSwitches();
    } else {
      this.syncNtfSwitches();
    }
  }

  // ---- sample rate groups ----

  private seedRateCurrent(info: DeviceInfo): void {
    const seeds: number[] = [info.eegSampleRate, info.emgSampleRate, info.accSampleRate,
      info.ppgSampleRate];
    const groups: RateGroup[] = this.rateGroups.slice();
    for (let i = 0; i < groups.length; i++) {
      for (let d = 0; d < RATE_DEFS.length; d++) {
        if (groups[i].key === RATE_DEFS[d].key && seeds[d] > 0) {
          groups[i].current = seeds[d];
        }
      }
    }
    this.rateGroups = groups;
  }

  private async syncRateGroups(): Promise<void> {
    const st: DeviceUiState | null = this.currentState();
    if (st === null || st.profile === null) {
      this.rateGroups = [];
      return;
    }
    const groups: RateGroup[] = [];
    for (const def of RATE_DEFS) {
      const list: string = await st.profile.getParam(def.key + '_LIST');
      if (list.length === 0 || isErrorResult(list)) {
        continue;
      }
      const options: number[] = [];
      for (const part of list.split('|')) {
        const rate: number = parseInt(part, 10);
        if (!isNaN(rate)) {
          options.push(rate);
        }
      }
      const usable: number[] = def.candidates.filter((rate: number) => options.includes(rate));
      if (usable.length === 0) {
        continue;
      }
      const group: RateGroup = new RateGroup();
      group.key = def.key;
      group.label = def.label;
      group.usable = usable;
      const current: string = await st.profile.getParam(def.key);
      const parsed: number = parseInt(current, 10);
      group.current = isNaN(parsed) ? 0 : parsed;
      groups.push(group);
    }
    this.rateGroups = groups;
    if (st.info !== null) {
      this.seedRateCurrent(st.info);
    }
  }

  private async onRateSelect(group: RateGroup, rate: number): Promise<void> {
    const st: DeviceUiState | null = this.currentState();
    if (st === null || st.profile === null) {
      return;
    }
    group.current = rate;
    this.rateGroups = this.rateGroups.slice();
    const result: string = await st.profile.setParam(group.key, rate.toString());
    this.appLog('User: setParam(' + group.key + ', ' + rate.toString() + ') -> ' + result, 'I', st);
    if (isErrorResult(result)) {
      this.errorLine = 'setParam ' + group.key + ' failed: ' + result;
    } else {
      this.errorLine = '';
      this.recordParam(st.mac, group.key, rate.toString());
      this.clearBuffers(st);
    }
    this.syncRateGroups();
  }

  // ---- live filter band ----

  private onBandSelect(index: number): void {
    this.liveFilterBand = index;
    this.appLog('User: live filter -> ' +
      (index < this.bandLabels.length ? this.bandLabels[index] : 'Off'));
    this.states.forEach((st: DeviceUiState): void => {
      st.liveFilter.setBand(index);
      const w: worker.ThreadWorker | undefined = this.dspWorkers.get(st.mac);
      if (w !== undefined) {
        w.postMessage({ kind: 'band', band: index });
      }
    });
  }

  private onEegPage(delta: number): void {
    const st: DeviceUiState | null = this.currentState();
    if (st === null) {
      return;
    }
    const next: number = Math.max(0, Math.min(this.bioPages - 1, st.eegPage + delta));
    st.eegPage = next;
    this.eegPageView = next;
    this.appLog('User: eeg page -> ' + next.toString(), 'D', st);
  }

  // ---- bin replay ----

  private binPaths(): string[] {
    const out: string[] = [];
    const parts: string[] = this.binPath.split(';');
    for (const part of parts) {
      const trimmed: string = part.trim();
      if (trimmed.length > 0) {
        out.push(trimmed);
      }
    }
    return out;
  }

  private async onReplayStart(multi: boolean): Promise<void> {
    if (this.replayMacs.size > 0) {
      this.errorLine = 'a replay session is already running';
      return;
    }
    if (this.hasLiveDevices()) {
      this.errorLine = 'replay rejected: live devices connected';
      return;
    }
    const paths: string[] = this.binPaths();
    if (paths.length === 0) {
      this.errorLine = 'no bin path';
      return;
    }
    this.appLog('User: replay bin file: ' + paths.join('; '));
    const macs: string[] = [];
    const sensors: SensorProfile[] = [];
    const infos: Map<string, DeviceInfo> = new Map<string, DeviceInfo>();
    for (const path of paths) {
      const info = await this.controller.getBinFileInfo(path);
      if (info === null || !info.valid) {
        this.appLog('App: invalid bin file (no config record): ' + path, 'W');
        this.errorLine = 'invalid bin: ' + path;
        return;
      }
      const sensor: SensorProfile | null = this.controller.requireSensor(info.mac);
      if (sensor === null) {
        this.errorLine = 'requireSensor failed: ' + info.mac;
        return;
      }
      macs.push(info.mac);
      sensors.push(sensor);
      infos.set(info.mac, info.deviceInfo);
    }
    this.errorLine = '';
    if (this.scanning) {
      this.controller.stopScan();
      this.scanning = false;
    }
    if (!multi || paths.length === 1) {
      const profile: SensorProfile | null =
        await this.controller.replayBinFile(paths[0], macs[0], true, OP_TIMEOUT_MS);
      if (profile === null) {
        this.errorLine = 'replayBinFile failed: ' + paths[0];
        return;
      }
      this.registerReplayProfile(macs[0], profile, infos.get(macs[0]) ?? null);
      return;
    }
    const started: string[] =
      await this.controller.multiReplayBinFile(paths, sensors, true, OP_TIMEOUT_MS);
    if (started.length === 0) {
      this.errorLine = 'multiReplayBinFile failed for all members';
      return;
    }
    for (const mac of started) {
      const profile: SensorProfile | null = this.controller.getSensor(mac);
      if (profile !== null) {
        this.registerReplayProfile(mac, profile, infos.get(mac) ?? null);
      }
    }
    this.messageLine = 'Replaying ' + started.length.toString() + ' bin files (realtime=true) ...';
  }

  private registerReplayProfile(mac: string, profile: SensorProfile, info: DeviceInfo | null): void {
    const st: DeviceUiState = this.ensureState(mac, profile);
    st.isReplay = true;
    st.resetSession();
    st.isReplay = true;
    if (info !== null) {
      st.info = info;
    }
    st.flowStarted = true;
    this.replayMacs.add(mac);
    this.replayActive = true;
    this.attachProfileListeners(st);
    this.addReplayRow(mac, profile.getDevice().name.length > 0 ? profile.getDevice().name : 'Replay');
    this.currentMac = mac;
    this.refreshStatus();
    this.refreshAllLines();
    this.syncPanel();
  }

  private async onReplayPauseResume(): Promise<void> {
    if (this.replayMacs.size === 0) {
      return;
    }
    const pause: boolean = !this.replayPaused;
    for (const mac of Array.from(this.replayMacs)) {
      const st: DeviceUiState | undefined = this.states.get(mac);
      const result: string = pause ? await this.controller.pauseBinReplay(mac) :
        await this.controller.resumeBinReplay(mac);
      this.appLog('User: ' + (pause ? 'pause' : 'resume') + ' replay -> ' + result,
        result === 'OK' ? 'I' : 'W', st);
    }
    this.replayPaused = pause;
    this.messageLine = pause ? 'Replay paused' : 'Replay resumed';
  }

  private async onReplayStop(): Promise<void> {
    for (const mac of Array.from(this.replayMacs)) {
      this.replayStopRequested.add(mac);
      const st: DeviceUiState | undefined = this.states.get(mac);
      const result: string = await this.controller.stopBinReplay(mac);
      this.appLog('User: stop replay -> ' + result, result === 'OK' ? 'I' : 'W', st);
      if (result !== 'OK') {
        this.replayStopRequested.delete(mac);
      }
    }
  }

  private async onAnalyzeBin(): Promise<void> {
    const paths: string[] = this.binPaths();
    if (paths.length === 0) {
      this.errorLine = 'no bin path';
      return;
    }
    this.appLog('User: analyze bin file: ' + paths[0]);
    this.binInfoLine = 'Analyzing ...';
    const result: string = await this.controller.parseBinToCsv(paths[0]);
    this.appLog('App: analyze -> ' + result);
    this.binInfoLine = 'Analyze: ' + result;
  }

  private async onBinInfo(): Promise<void> {
    const paths: string[] = this.binPaths();
    if (paths.length === 0) {
      this.errorLine = 'no bin path';
      return;
    }
    const info = await this.controller.getBinFileInfo(paths[0]);
    if (info === null) {
      this.binInfoLine = 'Bin info: unreadable';
      return;
    }
    this.binInfoLine = 'Bin: ' + info.deviceName + ' [' + info.mac + '] ' +
      info.durationSec.toFixed(1) + 's valid=' + info.valid.toString();
  }

  // ---- worklets (off-thread DSP) ----

  private ensureWorkletBinding(st: DeviceUiState): void {
    if (!this.useWorklets || st.workletActive || st.profile === null) {
      return;
    }
    const w: worker.ThreadWorker = new worker.ThreadWorker('entry/ets/workers/DspWorker.ets');
    w.onmessage = (e: MessageEvents): void => {
      const frame: DspFrame = e.data as DspFrame;
      if (frame.kind === 'unbound') {
        w.terminate();
        return;
      }
      if (frame.kind !== 'frame') {
        return;
      }
      const channels: Map<number, Float32Array[]> = new Map<number, Float32Array[]>();
      for (const key of Object.keys(frame.waves)) {
        channels.set(Number(key), frame.waves[key]);
      }
      st.dspChannels = channels;
      const specs: Map<string, SpectrumResult | null> = new Map<string, SpectrumResult | null>();
      for (const key of Object.keys(frame.specs)) {
        specs.set(key, frame.specs[key]);
      }
      st.dspSpectra = specs;
      const s: DspStatsPayload = frame.stats;
      st.batches += s.batches;
      st.totalSamples += s.samples;
      for (const key of Object.keys(s.rateSamples)) {
        st.noteRateSamples(Number(key), s.rateTags[key] ?? 0, s.rateSamples[key]);
      }
      for (const key of Object.keys(s.lostCounts)) {
        const type: number = Number(key);
        st.lostCounts.set(type, (st.lostCounts.get(type) ?? 0) + s.lostCounts[key]);
      }
      for (const key of Object.keys(s.counters)) {
        st.counters.set(key, (st.counters.get(key) ?? 0) + s.counters[key]);
      }
      for (const key of Object.keys(s.expectedRates)) {
        st.expectedRates.set(Number(key), s.expectedRates[key]);
      }
      for (const key of Object.keys(s.startTimeSecs)) {
        st.streamStartTimeSecs.set(Number(key), s.startTimeSecs[key]);
      }
      if (s.delayMs > 0) {
        st.streamDelayMs = s.delayMs;
      }
      for (const key of Object.keys(s.impedance)) {
        st.impedance.set(Number(key), s.impedance[key]);
      }
      st.gestureSeen = s.gestureSeen;
      st.gesture = s.gesture;
      st.rawGesture = s.rawGesture;
      st.possibility = s.possibility;
      st.strength = s.strength;
    };
    w.onerror = (err: ErrorEvent): void => {
      this.appLog('App: dsp worker error on ' + st.mac + ': ' + err.message, 'E', st);
      w.terminate();
    };
    this.dspWorkers.set(st.mac, w);
    st.workletActive = true;
    w.postMessage({ kind: 'reset', band: 0 });
    w.postMessage({ kind: 'band', band: this.liveFilterBand });
    w.postMessage({ kind: 'bind', handle: st.profile.handle.toString() });
    this.appLog('App: dsp worker bound: ' + st.mac, 'I', st);
  }

  private unbindWorklet(st: DeviceUiState): void {
    const w: worker.ThreadWorker | undefined = this.dspWorkers.get(st.mac);
    if (w !== undefined) {
      w.postMessage({ kind: 'unbind', band: 0 });
      this.dspWorkers.delete(st.mac);
    }
    st.workletActive = false;
    st.dspChannels.clear();
    st.dspSpectra.clear();
  }

  private onUseWorkletsToggle(isOn: boolean): void {
    this.appLog('User: use worker ' + (isOn ? 'ON' : 'OFF'));
    this.useWorklets = isOn;
    if (isOn) {
      this.states.forEach((st: DeviceUiState): void => {
        if (st.flowStarted) {
          this.ensureWorkletBinding(st);
        }
      });
    } else {
      this.states.forEach((st: DeviceUiState): void => {
        this.unbindWorklet(st);
      });
    }
  }

  // ---- data ----

  private onData(st: DeviceUiState, dataList: SensorData[]): void {
    this.feedAlgo(st, dataList);
    for (const data of dataList) {
      if (st.workletActive) {
        this.processBatch(st, data);
        continue;
      }
      const item: QueuedBatch = { st: st, data: this.cloneData ? data.clone() : data };
      this.dataQueue.push(item);
    }
    if (this.dataQueue.length > DATA_QUEUE_CAPACITY) {
      this.dataQueue.splice(0, this.dataQueue.length - DATA_QUEUE_CAPACITY);
    }
  }

  private feedAlgo(st: DeviceUiState, dataList: SensorData[]): void {
    const algo: SensorAlgo | null = st.algo;
    if (algo === null || !algo.hasInit()) {
      return;
    }
    let supported: boolean = false;
    for (const data of dataList) {
      const type: number = data.getDataType();
      if (type === DataType.NTF_EEG || type === DataType.NTF_IMU) {
        supported = true;
        break;
      }
    }
    if (!supported) {
      return;
    }
    algo.pushSamples(dataList, st.algoCloneMode ? 'CLONE' : '').then((ok: boolean): void => {
      if (!ok) {
        this.appLog('App: algo push batch failed', 'W', st);
      }
    });
  }

  private resetAlgo(st: DeviceUiState): void {
    st.algoResetGeneration++;
    st.lastRelaxStep = 0;
    st.lastRelaxTimestamp = -1.0;
    st.relax.clear();
    const w: worker.ThreadWorker | undefined = this.dspWorkers.get(st.mac);
    if (w !== undefined) {
      w.postMessage({ kind: 'reset', band: 0 });
    }
    this.dataQueue = this.dataQueue.filter((item: QueuedBatch): boolean => item.st !== st);
    if (st.algo !== null) {
      st.algo.reset();
    }
  }

  private refreshRelax(): void {
    const st: DeviceUiState | null = this.currentState();
    if (st === null || st.algo === null || this.relaxQueryPending || st.workletActive) {
      return;
    }
    if (st.info === null || st.info.ppgChannelCount <= 0) {
      return;
    }
    const algo: SensorAlgo = st.algo;
    const generation: number = st.algoResetGeneration;
    this.relaxQueryPending = true;
    algo.getResult('NO_HEADER').then((result: string): void => {
      this.relaxQueryPending = false;
      if (generation !== st.algoResetGeneration) {
        this.refreshRelax();
        return;
      }
      const fields: string[] = result.split('|');
      if (fields.length !== 6) {
        return;
      }
      const step: number = parseInt(fields[0], 10);
      const timestamp: number = parseFloat(fields[1]);
      const relax: number = parseFloat(fields[3]);
      if (isNaN(step) || isNaN(timestamp) || isNaN(relax) || step === st.lastRelaxStep) {
        return;
      }
      if (step < st.lastRelaxStep) {
        st.relax.clear();
        st.lastRelaxTimestamp = -1.0;
      }
      if (step > 0) {
        st.relax.ensureSize(1, 50 * 5);
        let slotCount: number = 1;
        if (timestamp > 0 && st.lastRelaxTimestamp > 0) {
          const dt: number = timestamp - st.lastRelaxTimestamp;
          if (dt > 0) {
            slotCount = Math.max(1, Math.min(Math.round(dt * 50), st.relax.length));
          }
        }
        if (timestamp > 0) {
          st.lastRelaxTimestamp = timestamp;
        }
        if (slotCount > 1) {
          const column: Float32Array = new Float32Array(slotCount);
          column.fill(st.relax.latest(0));
          column[slotCount - 1] = relax;
          st.relax.appendBatch([column]);
        } else {
          const single: Float32Array = new Float32Array(1);
          single[0] = relax;
          st.relax.appendBatch([single]);
        }
      }
      if (step > 0 && st.algoCsvFd >= 0) {
        const row: string = fields[0] + ',' + timestamp.toFixed(3) + ',' +
          fields.slice(2).join(',') + '\n';
        try {
          fs.writeSync(st.algoCsvFd, row);
        } catch (err) {
        }
      }
      st.lastRelaxStep = step;
      this.refreshRelax();
    });
  }

  private openAlgoCsv(st: DeviceUiState, deviceLogPath: string): void {
    if (deviceLogPath.length === 0 || isErrorResult(deviceLogPath) || deviceLogPath === 'True' ||
      deviceLogPath === 'False') {
      return;
    }
    const slash: number = deviceLogPath.lastIndexOf('/');
    const dot: number = deviceLogPath.lastIndexOf('.');
    const dir: string = slash >= 0 ? deviceLogPath.substring(0, slash + 1) : '';
    const base: string = deviceLogPath.substring(slash + 1,
      dot > slash + 1 ? dot : deviceLogPath.length);
    if (base.length === 0) {
      return;
    }
    const csvPath: string = dir + base + '.csv';
    if (st.algoCsvFd >= 0 && st.algoCsvPath === csvPath) {
      return;
    }
    st.closeAlgoCsv();
    try {
      const file: fs.File =
        fs.openSync(csvPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      st.algoCsvFd = file.fd;
      st.algoCsvPath = csvPath;
      fs.writeSync(st.algoCsvFd, 'STEP,TIMESTAMP,VALID,RELAX,CONCENTRATE,POSITION\n');
    } catch (err) {
      this.appLog('App: cannot open algo CSV: ' + csvPath, 'W', st);
    }
  }

  private drainDataQueue(): void {
    if (this.dataQueue.length === 0) {
      return;
    }
    const pending: QueuedBatch[] = this.dataQueue;
    this.dataQueue = [];
    for (const item of pending) {
      this.processBatch(item.st, item.data);
    }
  }

  private appendToBuffer(st: DeviceUiState, type: number, values: Float32Array[],
                         sampleRate: number): void {
    let buf: RingBuffer | undefined = st.buffers.get(type);
    if (buf === undefined) {
      buf = new RingBuffer();
      st.buffers.set(type, buf);
    }
    const seconds: number = BIO_TYPES.has(type) || type === DataType.NTF_MAG_ANGLE ? 1.0 : 5.0;
    buf.ensureSize(values.length, sampleRate * seconds);
    buf.appendBatch(values);
  }

  private processBatch(st: DeviceUiState, data: SensorData): void {
    const type: number = data.getDataType();
    st.batches += 1;
    st.totalSamples += data.getSampleCount();
    st.expectedRates.set(type, data.getSampleRate());
    st.lostCounts.set(type, (st.lostCounts.get(type) ?? 0) + data.getLostPackageCount());
    const fresh: boolean = data.isDataValid();
    if (fresh && data.isChannelEnabled(0)) {
      let valid: number = 0;
      for (let i = 0; i < data.getSampleCount(); i++) {
        if (!data.isLost(0, i)) {
          valid++;
        }
      }
      if (valid > 0) {
        st.noteRateSamples(type, data.getStartTimeStamp(), valid);
      }
    }
    if (data.getStartTimeSec() > 0) {
      st.streamStartTimeSecs.set(type, data.getStartTimeSec());
    }
    if (data.getDelay() > 0) {
      st.streamDelayMs = data.getDelay();
    }
    const counterKey: string = dataTypeName(type);
    st.counters.set(counterKey, (st.counters.get(counterKey) ?? 0) + 1);

    const last: number = data.getSampleCount() - 1;
    if (last < 0 || data.getChannelCount() <= 0) {
      return;
    }

    if (type === DataType.NTF_GEST) {
      if (data.isDataValid(0, last)) {
        st.gestureSeen = true;
        st.gesture = data.getData(0, last);
        st.rawGesture = data.getRawData(0, last);
        st.possibility = data.getImpedance(0, last);
        st.strength = data.getSaturation(0, last);
      }
      return;
    }

    if (type === DataType.NTF_IMPEDANCE || type === DataType.NTF_IMPEDANCE_EXT) {
      for (let ch = 0; ch < data.getChannelCount(); ch++) {
        if (data.isDataValid(ch, last)) {
          st.impedance.set(ch, data.getImpedance(ch, last));
        }
      }
      return;
    }

    if (type === DataType.NTF_IMU) {
      const split: number[][] = [
        [DataType.NTF_ACC, 0, 3],
        [DataType.NTF_GYRO, 3, 6],
        [DataType.NTF_EULER, 6, 9],
        [DataType.NTF_QUATERNION, 9, 13]
      ];
      for (const seg of split) {
        const segType: number = seg[0];
        const from: number = seg[1];
        const to: number = seg[2];
        if (data.getChannelCount() < to) {
          continue;
        }
        let valid: number = 0;
        if (fresh && data.isChannelEnabled(0)) {
          for (let i = 0; i < data.getSampleCount(); i++) {
            if (!data.isLost(from, i)) {
              valid++;
            }
          }
        }
        if (valid > 0) {
          st.noteRateSamples(segType, data.getStartTimeStamp(), valid);
        }
        st.expectedRates.set(segType, data.getSampleRate());
        if (data.getStartTimeSec() > 0) {
          st.streamStartTimeSecs.set(segType, data.getStartTimeSec());
        }
        if (st.workletActive) {
          continue;
        }
        const values: Float32Array[] = [];
        for (let ch = from; ch < to; ch++) {
          values.push(data.getChannelData(ch));
        }
        this.appendToBuffer(st, segType, values, data.getSampleRate());
      }
      return;
    }

    if (BIO_TYPES.has(type)) {
      for (let ch = 0; ch < data.getChannelCount(); ch++) {
        if (data.isDataValid(ch, last)) {
          st.impedance.set(ch, data.getImpedance(ch, last));
        }
      }
    }
    if (st.workletActive) {
      return;
    }
    const filter: boolean = LIVE_FILTER_TYPES.has(type);
    const values: Float32Array[] = [];
    for (let ch = 0; ch < data.getChannelCount(); ch++) {
      const channelValues: Float32Array = data.getChannelData(ch);
      if (filter) {
        st.liveFilter.apply(type, ch, channelValues, data.getSampleRate());
      }
      values.push(channelValues);
    }
    this.appendToBuffer(st, type, values, data.getSampleRate());
  }

  private settleStats(): void {
    const now: number = Date.now();
    this.states.forEach((st: DeviceUiState): void => {
      st.updateActualRates(now);
    });
    this.rateRotateIndex++;
    this.refreshAllLines();
    this.refreshBackendName();
  }

  // ---- bio page ----

  private impedanceSide(st: DeviceUiState, channel: number): string[] {
    const raw: number | undefined = st.impedance.get(channel);
    if (raw === undefined) {
      return ['', '#9E9E9E'];
    }
    const kohm: number = raw / 1000;
    const color: string = kohm <= 500 ? '#4CAF50' : kohm <= 999 ? '#FF9800' : '#F44336';
    return [kohm.toFixed(2) + ' KOhm', color];
  }

  private hasMagAngle(st: DeviceUiState): boolean {
    if (st.info !== null && st.info.magAngleChannelCount > 0) {
      return true;
    }
    if (st.workletActive) {
      return st.dspChannels.has(DataType.NTF_MAG_ANGLE);
    }
    return st.buffers.has(DataType.NTF_MAG_ANGLE);
  }

  private computeBioPlots(st: DeviceUiState): BioPlot[] {
    const plots: BioPlot[] = [];
    if (!this.isDisplayReady(st)) {
      return plots;
    }
    const info: DeviceInfo | null = st.info;
    if (info !== null && info.ppgChannelCount > 0) {
      plots.push({ title: 'RELAX', type: RELAX_PLOT_TYPE, channel: 0, spectrum: false,
        range: [], impedance: false });
      plots.push({ title: 'fp1', type: DataType.NTF_EEG, channel: 0, spectrum: true,
        range: [], impedance: true });
      plots.push({ title: 'fp2', type: DataType.NTF_EEG, channel: 1, spectrum: true,
        range: [], impedance: true });
      plots.push({ title: 'red_led', type: DataType.NTF_PPG, channel: 0, spectrum: true,
        range: [], impedance: true });
      plots.push({ title: 'ir_led', type: DataType.NTF_PPG, channel: 1, spectrum: true,
        range: [], impedance: true });
      plots.push({ title: 'spo2', type: DataType.NTF_SPO2, channel: 0, spectrum: false,
        range: [], impedance: true });
      plots.push({ title: 'heart_rate', type: DataType.NTF_SPO2, channel: 1, spectrum: false,
        range: [], impedance: true });
      return plots;
    }
    if (info !== null && info.eegChannelCount > 0) {
      const hasECG: boolean = info.ecgChannelCount > 0;
      const hasBRTH: boolean = info.brthChannelCount > 0;
      const hasMag: boolean = this.hasMagAngle(st);
      const perPage: number = 8 - (hasECG ? 1 : 0) - (hasBRTH ? 1 : 0) - (hasMag ? 1 : 0);
      const pages: number = Math.max(1, Math.ceil(info.eegChannelCount / perPage));
      const page: number = Math.min(st.eegPage, pages - 1);
      const start: number = page * perPage;
      for (let i = start; i < Math.min(start + perPage, info.eegChannelCount); i++) {
        plots.push({ title: 'EEG-' + (i + 1).toString(), type: DataType.NTF_EEG, channel: i,
          spectrum: true, range: [], impedance: true });
      }
      if (page === pages - 1) {
        if (hasMag) {
          plots.push({ title: 'Angle', type: DataType.NTF_MAG_ANGLE, channel: 0, spectrum: true,
            range: [0, 180], impedance: false });
        }
        if (hasECG) {
          plots.push({ title: 'ECG', type: DataType.NTF_ECG, channel: 0, spectrum: true,
            range: [], impedance: true });
        }
        if (hasBRTH) {
          plots.push({ title: 'BRTH', type: DataType.NTF_BRTH, channel: 0, spectrum: false,
            range: [], impedance: true });
        }
      }
      return plots;
    }
    const hasMag: boolean = this.hasMagAngle(st);
    let count: number = info !== null ? info.emgChannelCount : 0;
    if (count <= 0) {
      if (st.workletActive) {
        const chs: Float32Array[] | undefined = st.dspChannels.get(DataType.NTF_EMG);
        if (chs !== undefined) {
          count = chs.length;
        }
      } else {
        const buf: RingBuffer | undefined = st.buffers.get(DataType.NTF_EMG);
        if (buf !== undefined) {
          count = buf.channelCount;
        }
      }
    }
    const emgRows: number = Math.min(hasMag ? MAX_BIO_ROWS - 1 : MAX_BIO_ROWS, count);
    for (let i = 0; i < emgRows; i++) {
      plots.push({ title: 'EMG-' + (i + 1).toString(), type: DataType.NTF_EMG, channel: i,
        spectrum: true, range: [], impedance: true });
    }
    if (hasMag) {
      plots.push({ title: 'Angle', type: DataType.NTF_MAG_ANGLE, channel: 0, spectrum: true,
        range: [0, 180], impedance: false });
    }
    return plots;
  }

  private bioPageCount(st: DeviceUiState): number {
    const info: DeviceInfo | null = st.info;
    if (info === null || info.ppgChannelCount > 0 || info.eegChannelCount <= 0) {
      return 1;
    }
    const hasECG: boolean = info.ecgChannelCount > 0;
    const hasBRTH: boolean = info.brthChannelCount > 0;
    const hasMag: boolean = info.magAngleChannelCount > 0;
    const perPage: number = 8 - (hasECG ? 1 : 0) - (hasBRTH ? 1 : 0) - (hasMag ? 1 : 0);
    return Math.max(1, Math.ceil(info.eegChannelCount / perPage));
  }

  private spectrumFor(st: DeviceUiState, type: number, channel: number,
                      now: number): SpectrumResult | null {
    const key: string = 'bio:' + type.toString() + ':' + channel.toString();
    const at: number = st.spectraAt.get(key) ?? 0;
    if (now - at < SPECTRUM_INTERVAL_MS && st.spectra.has(key)) {
      return st.spectra.get(key) ?? null;
    }
    let result: SpectrumResult | null = null;
    const buf: RingBuffer | undefined = st.buffers.get(type);
    const rate: number = st.expectedRates.get(type) ?? 0;
    if (buf !== undefined && buf.length >= 16 && rate > 0 && channel < buf.channelCount) {
      result = computeSpectrum([buf.getChannel(channel)], rate);
    }
    st.spectra.set(key, result);
    st.spectraAt.set(key, now);
    return result;
  }

  private imuSpectrumFor(st: DeviceUiState, type: number, now: number): SpectrumResult | null {
    const key: string = 'imu:' + type.toString();
    const at: number = st.spectraAt.get(key) ?? 0;
    if (now - at < SPECTRUM_INTERVAL_MS && st.spectra.has(key)) {
      return st.spectra.get(key) ?? null;
    }
    let result: SpectrumResult | null = null;
    const buf: RingBuffer | undefined = st.buffers.get(type);
    const rate: number = st.expectedRates.get(type) ?? 0;
    if (buf !== undefined && buf.length >= 16 && rate > 0) {
      result = computeSpectrum(buf.getAllChannels(), rate);
    }
    st.spectra.set(key, result);
    st.spectraAt.set(key, now);
    return result;
  }

  private drawTick(): void {
    if (this.currentTab === 1) {
      this.drawBio();
    } else if (this.currentTab === 2) {
      this.drawImu();
    }
  }

  private drawBio(): void {
    if (!this.bioCanvasReady) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.bioContext;
    const w: number = ctx.width;
    const st: DeviceUiState | null = this.currentState();
    const plots: BioPlot[] = st !== null ? this.computeBioPlots(st) : [];
    const pages: number = st !== null ? this.bioPageCount(st) : 1;
    if (pages !== this.bioPages) {
      this.bioPages = pages;
    }
    const height: number = Math.max(1, plots.length) * ROW_HEIGHT;
    if (height !== this.bioCanvasHeight) {
      this.bioCanvasHeight = height;
    }
    ctx.clearRect(0, 0, w, this.bioCanvasHeight);
    if (st === null || plots.length === 0) {
      ctx.fillStyle = '#8E8E93';
      ctx.font = '13px sans-serif';
      ctx.fillText('No bio stream (connect a device first)', 10, 30);
      return;
    }
    const now: number = Date.now();
    for (let r = 0; r < plots.length; r++) {
      const plot: BioPlot = plots[r];
      const top: number = r * ROW_HEIGHT;
      const side: string[] = plot.impedance && st.impedanceEnabled ?
        this.impedanceSide(st, plot.channel) : ['', ''];
      const pin: number =
        plot.type === DataType.NTF_MAG_ANGLE || plot.type === RELAX_PLOT_TYPE ? r : plot.channel;
      let channelData: Float32Array = new Float32Array(0);
      if (plot.type === RELAX_PLOT_TYPE) {
        if (st.workletActive) {
          const rel: Float32Array[] | undefined = st.dspChannels.get(RELAX_PLOT_TYPE);
          if (rel !== undefined && rel.length > 0) {
            channelData = rel[0];
          }
        } else if (st.relax.length > 0) {
          channelData = st.relax.getChannel(0);
        }
      } else if (st.workletActive) {
        const chs: Float32Array[] | undefined = st.dspChannels.get(plot.type);
        if (chs !== undefined && plot.channel < chs.length) {
          channelData = chs[plot.channel];
        }
      } else {
        const buf: RingBuffer | undefined = st.buffers.get(plot.type);
        if (buf !== undefined && plot.channel < buf.channelCount) {
          channelData = buf.getChannel(plot.channel);
        }
      }
      if (!plot.spectrum) {
        drawWaveform(ctx, 0, top, w, ROW_HEIGHT, [channelData], pin, plot.title,
          side[0], side[1], plot.range);
        continue;
      }
      const half: number = w / 2;
      const spec: SpectrumResult | null = st.workletActive ?
        (st.dspSpectra.get('bio:' + plot.type.toString() + ':' + plot.channel.toString()) ?? null) :
        this.spectrumFor(st, plot.type, plot.channel, now);
      drawSpectrum(ctx, 0, top, half, ROW_HEIGHT, spec, pin, [plot.title],
        'Waiting for data ...');
      drawWaveform(ctx, half, top, w - half, ROW_HEIGHT, [channelData], pin, plot.title,
        side[0], side[1], plot.range);
    }
  }

  // ---- imu page ----

  private drawImu(): void {
    if (!this.imuCanvasReady) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.imuContext;
    const w: number = ctx.width;
    const st: DeviceUiState | null = this.currentState();
    const height: number = CUBE_HEIGHT + IMU_STREAMS.length * ROW_HEIGHT;
    if (height !== this.imuCanvasHeight) {
      this.imuCanvasHeight = height;
    }
    ctx.clearRect(0, 0, w, this.imuCanvasHeight);
    const now: number = Date.now();
    const ready: boolean = st !== null && this.isDisplayReady(st);

    let quat: number[] | null = null;
    if (ready && st !== null) {
      if (st.workletActive) {
        const chs: Float32Array[] = st.dspChannels.get(DataType.NTF_QUATERNION) ?? [];
        if (chs.length >= 4 && chs[0].length > 0) {
          quat = [chs[0][chs[0].length - 1], chs[1][chs[1].length - 1],
            chs[2][chs[2].length - 1], chs[3][chs[3].length - 1]];
        }
      } else {
        const qb: RingBuffer | undefined = st.buffers.get(DataType.NTF_QUATERNION);
        if (qb !== undefined && qb.channelCount >= 4) {
          quat = [qb.latest(0), qb.latest(1), qb.latest(2), qb.latest(3)];
        }
      }
    }
    drawCube(ctx, 0, 0, w, CUBE_HEIGHT, quat, ready ? 'No quaternion data' : 'Not connected');

    const valueLines: string[] = [];
    for (let s = 0; s < IMU_STREAMS.length; s++) {
      const def: ImuStreamDef = IMU_STREAMS[s];
      const top: number = CUBE_HEIGHT + s * ROW_HEIGHT;
      const half: number = w / 2;
      let channels: Float32Array[] = [];
      let spec: SpectrumResult | null = null;
      if (st !== null) {
        if (st.workletActive) {
          channels = st.dspChannels.get(def.type) ?? [];
          spec = st.dspSpectra.get('imu:' + def.type.toString()) ?? null;
        } else {
          const buf: RingBuffer | undefined = st.buffers.get(def.type);
          if (buf !== undefined) {
            channels = buf.getAllChannels();
          }
          spec = this.imuSpectrumFor(st, def.type, now);
        }
      }
      drawSpectrum(ctx, 0, top, half, ROW_HEIGHT, spec, -1, def.labels, 'Waiting for data ...');
      drawWaveform(ctx, half, top, w - half, ROW_HEIGHT, channels, 0, def.label, '', '', def.range);
      const parts: string[] = [];
      for (let c = 0; c < def.labels.length; c++) {
        let v: number = 0;
        if (st !== null) {
          if (st.workletActive) {
            if (c < channels.length && channels[c].length > 0) {
              v = channels[c][channels[c].length - 1];
            }
          } else {
            const buf: RingBuffer | undefined = st.buffers.get(def.type);
            if (buf !== undefined && c < buf.channelCount) {
              v = buf.latest(c);
            }
          }
        }
        parts.push(def.labels[c] + ': ' + (v >= 0 ? '+' : '') + v.toFixed(4));
      }
      valueLines.push(def.label + ': ' + parts.join('   '));
    }
    const values: string = valueLines.join('\n');
    if (values !== this.imuValues) {
      this.imuValues = values;
    }
  }

  // ---- pages ----

  @Builder
  LogBrowserSheet(): void {
    LogBrowser({
      rootDir: getContext(this).filesDir + '/sensorsdklog',
      rootLabel: 'sensorsdklog',
      onAppLog: (msg: string): void => {
        this.appLog(msg);
      },
      onReplayBin: (path: string): void => {
        this.binPath = path;
        this.showLogBrowser = false;
        this.onReplayStart(false);
      }
    })
  }

  @Builder
  DevicePage(): void {
    Scroll() {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Button('Start Scan')
            .fontSize(13)
            .enabled(!this.scanning)
            .onClick((): void => {
              this.onScanStart();
            })
          Button('Stop Scan')
            .fontSize(13)
            .enabled(this.scanning)
            .onClick((): void => {
              this.onScanStop();
            })
          Button('Connect')
            .fontSize(13)
            .enabled(this.currentMac.length > 0)
            .onClick((): void => {
              this.onConnect();
            })
          Button('Disconnect')
            .fontSize(13)
            .enabled(this.currentMac.length > 0)
            .onClick((): void => {
              this.onDisconnect();
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          Button('Multi Start')
            .fontSize(13)
            .onClick((): void => {
              this.onMultiStart();
            })
          Button('Multi Stop')
            .fontSize(13)
            .onClick((): void => {
              this.onMultiStop();
            })
          Button('Battery')
            .fontSize(13)
            .enabled(this.switchesEnabled)
            .onClick((): void => {
              this.onBatteryRead();
            })
        }
        .width('100%')

        Row({ space: 12 }) {
          Text('Auto Reconnect').fontSize(13)
          Toggle({ type: ToggleType.Switch, isOn: this.autoReconnect })
            .onChange((isOn: boolean): void => {
              this.onAutoReconnectToggle(isOn);
            })
          Text('Clone Data').fontSize(13)
          Toggle({ type: ToggleType.Switch, isOn: this.cloneData })
            .onChange((isOn: boolean): void => {
              this.appLog('User: clone data ' + (isOn ? 'ON' : 'OFF'));
              this.cloneData = isOn;
              this.states.forEach((st: DeviceUiState): void => {
                st.recreateAlgo(isOn);
              });
            })
        }
        .width('100%')

        Row({ space: 12 }) {
          Text('Use Worker (off-thread DSP)').fontSize(13)
          Toggle({ type: ToggleType.Switch, isOn: this.useWorklets })
            .onChange((isOn: boolean): void => {
              this.onUseWorkletsToggle(isOn);
            })
        }
        .width('100%')

        Row({ space: 12 }) {
          Text('SDK Debug Log').fontSize(13)
          Toggle({ type: ToggleType.Switch, isOn: this.debugLogEnabled })
            .onChange((isOn: boolean): void => {
              this.onDebugLogToggle(isOn);
            })
          Text('Debug Bin Data').fontSize(13)
          Toggle({ type: ToggleType.Switch, isOn: this.binDataEnabled })
            .onChange((isOn: boolean): void => {
              this.onBinDataToggle(isOn);
            })
        }
        .width('100%')

        Row({ space: 12 }) {
          Text('Translate IMU (split ACC/GYRO/EULER/QUAT)').fontSize(13)
          Toggle({ type: ToggleType.Switch, isOn: this.translateImu })
            .onChange((isOn: boolean): void => {
              this.onTranslateImuToggle(isOn);
            })
        }
        .width('100%')

        List({ space: 4 }) {
          ForEach(this.devices, (row: DeviceRow) => {
            ListItem() {
              Text(this.rowTitle(row))
                .fontSize(13)
                .width('100%')
                .padding(6)
                .backgroundColor(row.mac === this.currentMac ? '#D6E8FF' : '#FFFFFF')
                .onClick((): void => {
                  this.selectDevice(row.mac);
                })
            }
          }, (row: DeviceRow) => this.rowTitle(row) + ':' + (row.mac === this.currentMac).toString())
        }
        .width('100%')
        .height(180)

        Column({ space: 4 }) {
          Text(this.statusLine).fontSize(13).width('100%')
          if (this.messageLine.length > 0) {
            Text(this.messageLine).fontSize(13).width('100%')
          }
          Text(this.batteryLine).fontSize(13).width('100%')
          Text(this.countersLine).fontSize(13).width('100%')
          Text(this.rateLine).fontSize(12).width('100%')
          Text(this.lostLine).fontSize(12).width('100%')
          Text(this.linkLine).fontSize(12).width('100%')
          Text(this.infoLine1).fontSize(12).width('100%')
          Text(this.infoLine2).fontSize(12).width('100%')
          if (this.streamLine.length > 0) {
            Text(this.streamLine).fontSize(12).width('100%')
          }
          if (this.multiLine.length > 0) {
            Text(this.multiLine).fontSize(13).width('100%')
          }
          if (this.errorLine.length > 0) {
            Text(this.errorLine).fontSize(13).fontColor('#CC0000').width('100%')
          }
        }
        .width('100%')
        .padding({ top: 4 })

        Text('Data Notification').fontSize(12).fontColor('#8E8E93').width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.ntfItems, (item: NtfItem) => {
            if (item.visible) {
              Row({ space: 4 }) {
                Text(item.label).fontSize(13)
                Toggle({ type: ToggleType.Switch, isOn: item.checked })
                  .enabled(this.switchesEnabled)
                  .onChange((isOn: boolean): void => {
                    this.onParamToggle(item.key, isOn, false);
                  })
              }
              .margin({ right: 12, top: 4 })
            }
          }, (item: NtfItem) => item.key + ':' + item.checked.toString() + ':' +
            item.visible.toString())
        }
        .width('100%')

        Text('Filter').fontSize(12).fontColor('#8E8E93').width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.filterItems, (item: FilterItem) => {
            Row({ space: 4 }) {
              Text(item.label).fontSize(13)
              Toggle({ type: ToggleType.Switch, isOn: item.checked })
                .enabled(this.switchesEnabled && this.filterSupported)
                .onChange((isOn: boolean): void => {
                  this.onParamToggle(item.key, isOn, true);
                })
            }
            .margin({ right: 12, top: 4 })
          }, (item: FilterItem) => item.key + ':' + item.checked.toString())
        }
        .width('100%')

        ForEach(this.rateGroups, (group: RateGroup) => {
          Row({ space: 6 }) {
            Text(group.label + ' rate').fontSize(13)
            ForEach(group.usable, (rate: number) => {
              Button(rate.toString())
                .fontSize(12)
                .height(28)
                .enabled(this.switchesEnabled)
                .backgroundColor(rate === group.current ? '#007DFF' : '#EEEEEE')
                .fontColor(rate === group.current ? '#FFFFFF' : '#000000')
                .onClick((): void => {
                  this.onRateSelect(group, rate);
                })
            }, (rate: number) => group.key + '_' + rate.toString() + '_' +
              (rate === group.current).toString())
          }
          .width('100%')
        }, (group: RateGroup) => group.key + '_' + group.usable.join(',') + '_' +
          group.current.toString())

        Text('Gesture').fontSize(12).fontColor('#8E8E93').width('100%')
        Column({ space: 2 }) {
          ForEach(this.gestureLines, (line: string) => {
            Text(line).fontSize(12).width('100%')
          }, (line: string) => line)
        }
        .width('100%')
        .padding(6)
        .backgroundColor('#F0F0F0')

        Column({ space: 6 }) {
          Text('Bin Replay (separate multiple paths with ;)').fontSize(13).width('100%')
          TextInput({ text: this.binPath, placeholder: '/path/to/test.bin' })
            .fontSize(13)
            .width('100%')
            .onChange((value: string): void => {
              this.binPath = value;
            })
          Row({ space: 8 }) {
            Button('Replay Bin')
              .fontSize(13)
              .onClick((): void => {
                this.showLogBrowser = true;
              })
            Button('Multi Replay Bin')
              .fontSize(13)
              .onClick((): void => {
                this.onReplayStart(true);
              })
            Button(this.replayPaused ? 'Resume' : 'Pause')
              .fontSize(13)
              .enabled(this.replayActive)
              .onClick((): void => {
                this.onReplayPauseResume();
              })
            Button('Stop')
              .fontSize(13)
              .enabled(this.replayActive)
              .onClick((): void => {
                this.onReplayStop();
              })
          }
          .width('100%')
          Row({ space: 8 }) {
            Button('Analyze Bin')
              .fontSize(13)
              .onClick((): void => {
                this.onAnalyzeBin();
              })
            Button('Bin Info')
              .fontSize(13)
              .onClick((): void => {
                this.onBinInfo();
              })
          }
          .width('100%')
          if (this.binInfoLine.length > 0) {
            Text(this.binInfoLine).fontSize(13).width('100%')
          }
        }
        .width('100%')
        .padding({ top: 4 })
      }
      .width('100%')
      .padding(8)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  BioPage(): void {
    Column({ space: 8 }) {
      Text('Live Filter (EMG/EEG/ECG/BRTH/PPG/SpO2)').fontSize(12).fontColor('#8E8E93').width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.bandLabels, (label: string, idx: number) => {
          Button(label)
            .fontSize(12)
            .height(28)
            .margin({ right: 4, top: 2 })
            .backgroundColor(idx === this.liveFilterBand ? '#007DFF' : '#EEEEEE')
            .fontColor(idx === this.liveFilterBand ? '#FFFFFF' : '#000000')
            .onClick((): void => {
              this.onBandSelect(idx);
            })
        }, (label: string, idx: number) => label + ':' + (idx === this.liveFilterBand).toString())
      }
      .width('100%')

      if (this.bioPages > 1) {
        Row({ space: 12 }) {
          Button('Prev')
            .fontSize(12)
            .height(28)
            .enabled(this.eegPageView > 0)
            .onClick((): void => {
              this.onEegPage(-1);
            })
          Text('Page ' + (this.eegPageView + 1).toString() + ' / ' + this.bioPages.toString())
            .fontSize(12)
          Button('Next')
            .fontSize(12)
            .height(28)
            .enabled(this.eegPageView < this.bioPages - 1)
            .onClick((): void => {
              this.onEegPage(1);
            })
        }
      }

      Scroll() {
        Canvas(this.bioContext)
          .width('100%')
          .height(this.bioCanvasHeight)
          .onReady((): void => {
            this.bioCanvasReady = true;
          })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollable(ScrollDirection.Vertical)
    }
    .width('100%')
    .height('100%')
    .padding(8)
  }

  @Builder
  ImuPage(): void {
    Column({ space: 8 }) {
      Text('Real-time Values').fontSize(12).fontColor('#8E8E93').width('100%')
      Text(this.imuValues).fontSize(11).width('100%')
      Scroll() {
        Canvas(this.imuContext)
          .width('100%')
          .height(this.imuCanvasHeight)
          .onReady((): void => {
            this.imuCanvasReady = true;
          })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollable(ScrollDirection.Vertical)
    }
    .width('100%')
    .height('100%')
    .padding(8)
  }

  build(): void {
    Column() {
      Text(this.demoTitle)
        .fontSize(15)
        .width('100%')
        .padding(8)
      Tabs({ barPosition: BarPosition.End }) {
        TabContent() {
          this.DevicePage()
        }
        .tabBar('Device')

        TabContent() {
          this.BioPage()
        }
        .tabBar('Bio')

        TabContent() {
          this.ImuPage()
        }
        .tabBar('IMU')
      }
      .layoutWeight(1)
      .width('100%')
      .onChange((index: number): void => {
        this.currentTab = index;
      })
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showLogBrowser, this.LogBrowserSheet(), {
      height: SheetSize.LARGE,
      showClose: true,
      dragBar: true
    })
  }
}
