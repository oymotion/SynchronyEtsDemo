import { SensorProfile, SensorAlgo, DeviceInfo } from 'sensor';
import { LiveFilter } from '../dsp/LiveFilter';
import { SpectrumResult } from '../dsp/SpectrumCompute';
import { RingBuffer } from './RingBuffer';
import fs from '@ohos.file.fs';

const POWER_STABLE_BAND: number = 4;

export class DeviceUiState {
  mac: string = '';
  profile: SensorProfile | null = null;
  info: DeviceInfo | null = null;
  power: number = -1;
  buffers: Map<number, RingBuffer> = new Map<number, RingBuffer>();
  impedance: Map<number, number> = new Map<number, number>();
  expectedRates: Map<number, number> = new Map<number, number>();
  actualRates: Map<number, number> = new Map<number, number>();
  rateTotalCounts: Map<number, number> = new Map<number, number>();
  rateStreamStartMs: Map<number, number> = new Map<number, number>();
  rateStreamTags: Map<number, number> = new Map<number, number>();
  rateLastDataMs: number = 0;
  lostCounts: Map<number, number> = new Map<number, number>();
  counters: Map<string, number> = new Map<string, number>();
  batches: number = 0;
  totalSamples: number = 0;
  gestureSeen: boolean = false;
  gesture: number = 0;
  rawGesture: number = 0;
  possibility: number = 0;
  strength: number = 0;
  liveFilter: LiveFilter = new LiveFilter();
  flowStarted: boolean = false;
  flowRunning: boolean = false;
  isReplay: boolean = false;
  streaming: boolean = false;
  replayStreamingSeen: boolean = false;
  streamStartTimeSecs: Map<number, number> = new Map<number, number>();
  streamDelayMs: number = 0;
  impedanceEnabled: boolean = false;
  eegPage: number = 0;
  spectra: Map<string, SpectrumResult | null> = new Map<string, SpectrumResult | null>();
  spectraAt: Map<string, number> = new Map<string, number>();
  workletActive: boolean = false;
  dspChannels: Map<number, Float32Array[]> = new Map<number, Float32Array[]>();
  dspSpectra: Map<string, SpectrumResult | null> = new Map<string, SpectrumResult | null>();
  relax: RingBuffer = new RingBuffer();
  algo: SensorAlgo | null = null;
  algoCreating: boolean = false;
  algoCloneMode: boolean = false;
  lastRelaxStep: number = 0;
  lastRelaxTimestamp: number = -1.0;
  algoResetGeneration: number = 0;
  algoCsvFd: number = -1;
  algoCsvPath: string = '';

  private algoCreateSeq: number = 0;

  async recreateAlgo(cloneMode: boolean): Promise<void> {
    this.algoCloneMode = cloneMode;
    this.algoResetGeneration++;
    this.lastRelaxStep = 0;
    this.lastRelaxTimestamp = -1.0;
    this.relax.clear();
    const prev: SensorAlgo | null = this.algo;
    this.algo = null;
    if (prev !== null) {
      prev.destroy();
    }
    const seq: number = ++this.algoCreateSeq;
    this.algoCreating = true;
    try {
      const algo: SensorAlgo = new SensorAlgo();
      const ok: boolean = await algo.init();
      if (ok) {
        await algo.setParam('CLONE', cloneMode ? 'True' : 'False');
        await algo.setParam('EEG_REFRESH_RATE', '1');
      }
      if (seq !== this.algoCreateSeq) {
        algo.destroy();
        return;
      }
      if (ok) {
        this.algo = algo;
      } else {
        algo.destroy();
      }
    } catch (err) {
    } finally {
      if (seq === this.algoCreateSeq) {
        this.algoCreating = false;
      }
    }
  }

  closeAlgoCsv(): void {
    if (this.algoCsvFd < 0) {
      return;
    }
    try {
      fs.closeSync(this.algoCsvFd);
    } catch (err) {
    }
    this.algoCsvFd = -1;
    this.algoCsvPath = '';
  }

  discardAlgo(): void {
    this.algoCreateSeq++;
    if (this.algo !== null) {
      this.algo.destroy();
      this.algo = null;
    }
  }

  applyPower(power: number): void {
    if (power < 0) {
      return;
    }
    if (this.power < 0 || Math.abs(power - this.power) >= POWER_STABLE_BAND) {
      this.power = power;
    }
  }

  noteRateSamples(type: number, sessionTag: number, valid: number): void {
    const now: number = Date.now();
    if (this.rateStreamTags.get(type) !== sessionTag) {
      this.rateStreamTags.set(type, sessionTag);
      this.rateTotalCounts.set(type, 0);
      this.rateStreamStartMs.set(type, now);
    }
    this.rateTotalCounts.set(type, (this.rateTotalCounts.get(type) ?? 0) + valid);
    this.rateLastDataMs = now;
  }

  updateActualRates(now: number): void {
    if (this.rateLastDataMs > 0 && now - this.rateLastDataMs > 2000) {
      this.actualRates.clear();
      this.rateTotalCounts.clear();
      this.rateStreamStartMs.clear();
      this.rateStreamTags.clear();
      this.rateLastDataMs = 0;
      return;
    }
    this.actualRates.clear();
    this.rateTotalCounts.forEach((total: number, type: number): void => {
      const start: number = this.rateStreamStartMs.get(type) ?? now;
      this.actualRates.set(type, total / Math.max((now - start) / 1000, 0.001));
    });
  }

  resetSession(): void {
    this.buffers.forEach((buf: RingBuffer): void => {
      buf.clear();
    });
    this.impedance.clear();
    this.expectedRates.clear();
    this.actualRates.clear();
    this.rateTotalCounts.clear();
    this.rateStreamStartMs.clear();
    this.rateStreamTags.clear();
    this.rateLastDataMs = 0;
    this.lostCounts.clear();
    this.counters.clear();
    this.batches = 0;
    this.totalSamples = 0;
    this.gestureSeen = false;
    this.power = -1;
    this.flowStarted = false;
    this.streaming = false;
    this.replayStreamingSeen = false;
    this.streamStartTimeSecs.clear();
    this.streamDelayMs = 0;
    this.impedanceEnabled = false;
    this.eegPage = 0;
    this.liveFilter.reset();
    this.spectra.clear();
    this.spectraAt.clear();
    this.workletActive = false;
    this.dspChannels.clear();
    this.dspSpectra.clear();
    this.relax.clear();
    this.lastRelaxStep = 0;
    this.lastRelaxTimestamp = -1.0;
    this.algoResetGeneration++;
    if (this.algo !== null) {
      this.algo.reset();
    }
    this.closeAlgoCsv();
  }
}
