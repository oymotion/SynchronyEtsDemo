import { worker, ThreadWorkerGlobalScope, MessageEvents } from '@kit.ArkTS';
import { RingBuffer } from '../pages/RingBuffer';
import { LiveFilter } from '../dsp/LiveFilter';
import { computeSpectrum, SpectrumResult } from '../dsp/SpectrumCompute';
import { DataType, dataTypeName, SensorProfile, SensorData, SensorAlgo } from 'sensor';

const SPECTRUM_INTERVAL_MS: number = 200;
const FRAME_INTERVAL_MS: number = 50;

const BIO_TYPES: Set<number> = new Set<number>([
  DataType.NTF_EMG, DataType.NTF_EEG, DataType.NTF_ECG, DataType.NTF_BRTH,
  DataType.NTF_PPG, DataType.NTF_SPO2
]);
const LIVE_FILTER_TYPES: Set<number> = BIO_TYPES;
const DISPLAY_TYPES: Set<number> = new Set<number>([
  DataType.NTF_EMG, DataType.NTF_EEG, DataType.NTF_ECG, DataType.NTF_BRTH,
  DataType.NTF_PPG, DataType.NTF_SPO2, DataType.NTF_ANGLE, DataType.NTF_IMU,
  DataType.NTF_ACC, DataType.NTF_GYRO, DataType.NTF_EULER, DataType.NTF_QUATERNION
]);

interface BindMessage {
  kind: string;
  handle: string;
}

interface ControlMessage {
  kind: string;
  band: number;
}

interface StatsPayload {
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

interface FrameMessage {
  kind: string;
  waves: Record<string, Float32Array[]>;
  specs: Record<string, SpectrumResult | null>;
  stats: StatsPayload;
}

const port: ThreadWorkerGlobalScope = worker.workerPort;

const liveFilter: LiveFilter = new LiveFilter();
const buffers: Map<number, RingBuffer> = new Map<number, RingBuffer>();
const rates: Map<number, number> = new Map<number, number>();
const spectra: Map<string, SpectrumResult | null> = new Map<string, SpectrumResult | null>();
const spectraAt: Map<string, number> = new Map<string, number>();

let boundProfile: SensorProfile | null = null;

let algo: SensorAlgo | null = null;
let algoBindSeq: number = 0;
let relaxStep: number = 0;
let relaxTs: number = -1.0;
let relaxPending: boolean = false;
const relaxBuf: RingBuffer = new RingBuffer();

function algoReset(): void {
  if (algo !== null) {
    algo.reset();
  }
  relaxBuf.clear();
  relaxStep = 0;
  relaxTs = -1.0;
}

function algoFeed(dataList: SensorData[]): void {
  const a: SensorAlgo | null = algo;
  if (a === null || !a.hasInit()) {
    return;
  }
  for (const data of dataList) {
    const type: number = data.getDataType();
    if (type === DataType.NTF_EEG || type === DataType.NTF_IMU) {
      a.pushSamples(dataList);
      return;
    }
  }
}

function algoPoll(): void {
  const a: SensorAlgo | null = algo;
  if (a === null || relaxPending) {
    return;
  }
  relaxPending = true;
  a.getResult('NO_HEADER').then((result: string): void => {
    relaxPending = false;
    const fields: string[] = result.split('|');
    if (fields.length !== 6) {
      return;
    }
    const step: number = parseInt(fields[0], 10);
    const timestamp: number = parseFloat(fields[1]);
    const relax: number = parseFloat(fields[3]);
    if (isNaN(step) || isNaN(timestamp) || isNaN(relax) || step === relaxStep) {
      return;
    }
    if (step < relaxStep) {
      relaxBuf.clear();
      relaxTs = -1.0;
    }
    if (step > 0) {
      relaxBuf.ensureSize(1, 50 * 5);
      let slotCount: number = 1;
      if (timestamp > 0 && relaxTs > 0) {
        const dt: number = timestamp - relaxTs;
        if (dt > 0) {
          slotCount = Math.max(1, Math.min(Math.round(dt * 50), relaxBuf.length));
        }
      }
      if (timestamp > 0) {
        relaxTs = timestamp;
      }
      if (slotCount > 1) {
        const column: Float32Array = new Float32Array(slotCount);
        column.fill(relaxBuf.latest(0));
        column[slotCount - 1] = relax;
        relaxBuf.appendBatch([column]);
      } else {
        const single: Float32Array = new Float32Array(1);
        single[0] = relax;
        relaxBuf.appendBatch([single]);
      }
    }
    relaxStep = step;
    algoPoll();
  });
}

let statBatches: number = 0;
let statSamples: number = 0;
const statRateSamples: Map<number, number> = new Map<number, number>();
const statRateTags: Map<number, number> = new Map<number, number>();
const statLostCounts: Map<number, number> = new Map<number, number>();
const statCounters: Map<string, number> = new Map<string, number>();
const statExpectedRates: Map<number, number> = new Map<number, number>();
const statStartTimeSecs: Map<number, number> = new Map<number, number>();
let statDelayMs: number = 0;
const statImpedance: Map<number, number> = new Map<number, number>();
let gestureSeen: boolean = false;
let gestureValue: number = 0;
let rawGestureValue: number = 0;
let possibilityValue: number = 0;
let strengthValue: number = 0;

function addTo(map: Map<number, number>, key: number, delta: number): void {
  map.set(key, (map.get(key) ?? 0) + delta);
}

function numMapToRecord(map: Map<number, number>): Record<string, number> {
  const out: Record<string, number> = {};
  map.forEach((value: number, key: number): void => {
    out[key.toString()] = value;
  });
  return out;
}

function strMapToRecord(map: Map<string, number>): Record<string, number> {
  const out: Record<string, number> = {};
  map.forEach((value: number, key: string): void => {
    out[key] = value;
  });
  return out;
}

function processStats(data: SensorData): void {
  const type: number = data.getDataType();
  statBatches += 1;
  statSamples += data.getSampleCount();
  statExpectedRates.set(type, data.getSampleRate());
  addTo(statLostCounts, type, data.getLostPackageCount());
  const fresh: boolean = data.isDataValid();
  if (fresh && data.isChannelEnabled(0)) {
    let valid: number = 0;
    for (let i = 0; i < data.getSampleCount(); i++) {
      if (!data.isLost(0, i)) {
        valid++;
      }
    }
    if (valid > 0) {
      addTo(statRateSamples, type, valid);
      statRateTags.set(type, data.getStartTimeStamp());
    }
  }
  if (data.getStartTimeSec() > 0) {
    statStartTimeSecs.set(type, data.getStartTimeSec());
  }
  if (data.getDelay() > 0) {
    statDelayMs = data.getDelay();
  }
  const counterKey: string = dataTypeName(type);
  statCounters.set(counterKey, (statCounters.get(counterKey) ?? 0) + 1);

  const last: number = data.getSampleCount() - 1;
  if (last < 0 || data.getChannelCount() <= 0) {
    return;
  }

  if (type === DataType.NTF_GEST) {
    if (data.isDataValid(0, last)) {
      gestureSeen = true;
      gestureValue = data.getData(0, last);
      rawGestureValue = data.getRawData(0, last);
      possibilityValue = data.getImpedance(0, last);
      strengthValue = data.getSaturation(0, last);
    }
    return;
  }

  if (type === DataType.NTF_IMPEDANCE || type === DataType.NTF_IMPEDANCE_EXT) {
    for (let ch = 0; ch < data.getChannelCount(); ch++) {
      if (data.isDataValid(ch, last)) {
        statImpedance.set(ch, data.getImpedance(ch, last));
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
        addTo(statRateSamples, segType, valid);
        statRateTags.set(segType, data.getStartTimeStamp());
      }
      statExpectedRates.set(segType, data.getSampleRate());
      if (data.getStartTimeSec() > 0) {
        statStartTimeSecs.set(segType, data.getStartTimeSec());
      }
    }
    return;
  }

  if (BIO_TYPES.has(type)) {
    for (let ch = 0; ch < data.getChannelCount(); ch++) {
      if (data.isDataValid(ch, last)) {
        statImpedance.set(ch, data.getImpedance(ch, last));
      }
    }
  }
}

function appendToBuffer(type: number, values: Float32Array[], sampleRate: number): void {
  let buf: RingBuffer | undefined = buffers.get(type);
  if (buf === undefined) {
    buf = new RingBuffer();
    buffers.set(type, buf);
  }
  const seconds: number = BIO_TYPES.has(type) || type === DataType.NTF_ANGLE ? 1.0 : 5.0;
  buf.ensureSize(values.length, sampleRate * seconds);
  buf.appendBatch(values);
  rates.set(type, sampleRate);
}

function handleBatch(dataType: number, sampleRate: number, channels: Float32Array[]): void {
  if (dataType === DataType.NTF_IMU) {
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
      if (channels.length < to) {
        continue;
      }
      appendToBuffer(segType, channels.slice(from, to), sampleRate);
    }
    return;
  }
  if (LIVE_FILTER_TYPES.has(dataType)) {
    for (let ch = 0; ch < channels.length; ch++) {
      liveFilter.apply(dataType, ch, channels[ch], sampleRate);
    }
  }
  appendToBuffer(dataType, channels, sampleRate);
}

function handleData(dataList: SensorData[]): void {
  algoFeed(dataList);
  for (const data of dataList) {
    processStats(data);
    const type: number = data.getDataType();
    if (!DISPLAY_TYPES.has(type) || !data.isDataValid()) {
      continue;
    }
    const channels: Float32Array[] = [];
    for (let ch = 0; ch < data.getChannelCount(); ch++) {
      channels.push(data.getChannelData(ch));
    }
    handleBatch(type, data.getSampleRate(), channels);
  }
}

function spectrumFor(key: string, channels: Float32Array[], rate: number, now: number): void {
  const at: number = spectraAt.get(key) ?? 0;
  if (now - at < SPECTRUM_INTERVAL_MS && spectra.has(key)) {
    return;
  }
  let result: SpectrumResult | null = null;
  if (channels.length > 0 && channels[0].length >= 16 && rate > 0) {
    result = computeSpectrum(channels, rate);
  }
  spectra.set(key, result);
  spectraAt.set(key, now);
}

function emitFrame(): void {
  const now: number = Date.now();
  algoPoll();
  const waves: Record<string, Float32Array[]> = {};
  if (relaxBuf.channelCount > 0 && relaxBuf.length > 0) {
    waves['-1'] = relaxBuf.getAllChannels();
  }
  buffers.forEach((buf: RingBuffer, type: number): void => {
    if (buf.channelCount > 0 && buf.length > 0) {
      const channels: Float32Array[] = buf.getAllChannels();
      waves[type.toString()] = channels;
      const rate: number = rates.get(type) ?? 0;
      if (BIO_TYPES.has(type) || type === DataType.NTF_ANGLE) {
        for (let ch = 0; ch < buf.channelCount; ch++) {
          spectrumFor('bio:' + type.toString() + ':' + ch.toString(), [channels[ch]], rate, now);
        }
      } else {
        spectrumFor('imu:' + type.toString(), channels, rate, now);
      }
    }
  });
  const specs: Record<string, SpectrumResult | null> = {};
  spectra.forEach((value: SpectrumResult | null, key: string): void => {
    specs[key] = value;
  });
  const stats: StatsPayload = {
    batches: statBatches,
    samples: statSamples,
    rateSamples: numMapToRecord(statRateSamples),
    rateTags: numMapToRecord(statRateTags),
    lostCounts: numMapToRecord(statLostCounts),
    counters: strMapToRecord(statCounters),
    expectedRates: numMapToRecord(statExpectedRates),
    startTimeSecs: numMapToRecord(statStartTimeSecs),
    delayMs: statDelayMs,
    impedance: numMapToRecord(statImpedance),
    gestureSeen: gestureSeen,
    gesture: gestureValue,
    rawGesture: rawGestureValue,
    possibility: possibilityValue,
    strength: strengthValue
  };
  statBatches = 0;
  statSamples = 0;
  statRateSamples.clear();
  statRateTags.clear();
  statLostCounts.clear();
  statCounters.clear();
  const frame: FrameMessage = { kind: 'frame', waves: waves, specs: specs, stats: stats };
  port.postMessage(frame);
}

function resetStats(): void {
  statBatches = 0;
  statSamples = 0;
  statRateSamples.clear();
  statRateTags.clear();
  statLostCounts.clear();
  statCounters.clear();
  statExpectedRates.clear();
  statStartTimeSecs.clear();
  statDelayMs = 0;
  statImpedance.clear();
  gestureSeen = false;
  gestureValue = 0;
  rawGestureValue = 0;
  possibilityValue = 0;
  strengthValue = 0;
}

port.onmessage = (e: MessageEvents): void => {
  const msg = e.data as BindMessage | ControlMessage;
  if (msg.kind === 'bind') {
    if (boundProfile !== null) {
      boundProfile.useWorker(null);
      boundProfile = null;
    }
    const seq: number = ++algoBindSeq;
    const newAlgo: SensorAlgo = new SensorAlgo();
    newAlgo.init().then(async (ok: boolean): Promise<void> => {
      if (seq !== algoBindSeq || !ok) {
        newAlgo.destroy();
        return;
      }
      try {
        await newAlgo.setParam('CLONE', 'False');
        await newAlgo.setParam('EEG_REFRESH_RATE', '1');
        if (seq !== algoBindSeq) {
          newAlgo.destroy();
          return;
        }
        algo = newAlgo;
      } catch (err) {
        newAlgo.destroy();
      }
    });
    const profile: SensorProfile = new SensorProfile(BigInt((msg as BindMessage).handle), true);
    boundProfile = profile;
    profile.useWorker(port, (p: SensorProfile, dataList: SensorData[]): void => {
      handleData(dataList);
    });
    port.postMessage({ kind: 'bound' });
    return;
  }
  if (msg.kind === 'unbind') {
    algoBindSeq++;
    if (algo !== null) {
      algo.destroy();
      algo = null;
    }
    relaxBuf.clear();
    relaxStep = 0;
    relaxTs = -1.0;
    if (boundProfile !== null) {
      boundProfile.useWorker(null);
      boundProfile = null;
    }
    port.postMessage({ kind: 'unbound' });
    return;
  }
  if (msg.kind === 'band') {
    liveFilter.setBand((msg as ControlMessage).band);
    spectra.clear();
    spectraAt.clear();
    return;
  }
  if (msg.kind === 'clear') {
    buffers.forEach((buf: RingBuffer): void => {
      buf.clear();
    });
    spectra.clear();
    spectraAt.clear();
    statImpedance.clear();
    return;
  }
  if (msg.kind === 'reset') {
    buffers.clear();
    rates.clear();
    spectra.clear();
    spectraAt.clear();
    liveFilter.reset();
    algoReset();
    resetStats();
    return;
  }
};

setInterval(emitFrame, FRAME_INTERVAL_MS);
