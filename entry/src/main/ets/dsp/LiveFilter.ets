interface Band {
  label: string;
  lo: number;
  hi: number;
}

const BANDS: Band[] = [
  { label: 'Off', lo: 0, hi: 0 },
  { label: 'δ 0.5-4Hz', lo: 0.5, hi: 4 },
  { label: 'θ 4-8Hz', lo: 4, hi: 8 },
  { label: 'α 8-13Hz', lo: 8, hi: 13 },
  { label: 'β 13-30Hz', lo: 13, hi: 30 },
  { label: 'γ 30-45Hz', lo: 30, hi: 45 }
];
const ORDER: number = 4;
const PI: number = 3.14159265358979323846;

interface Biquad {
  b0: number;
  b1: number;
  b2: number;
  a1: number;
  a2: number;
}

interface StreamState {
  band: number;
  rate: number;
  sections: Biquad[];
  zi0: number[][];
  channels: Map<number, number[][]>;
}

class C {
  readonly re: number;
  readonly im: number;

  constructor(re: number, im: number) {
    this.re = re;
    this.im = im;
  }

  static polar(r: number, theta: number): C {
    return new C(r * Math.cos(theta), r * Math.sin(theta));
  }

  static real(v: number): C {
    return new C(v, 0);
  }

  static sqrtOf(c: C): C {
    const m: number = Math.sqrt(c.abs());
    const a: number = Math.atan2(c.im, c.re) / 2;
    return new C(m * Math.cos(a), m * Math.sin(a));
  }

  add(o: C): C {
    return new C(this.re + o.re, this.im + o.im);
  }

  addScalar(v: number): C {
    return new C(this.re + v, this.im);
  }

  sub(o: C): C {
    return new C(this.re - o.re, this.im - o.im);
  }

  mul(o: C): C {
    return new C(this.re * o.re - this.im * o.im, this.re * o.im + this.im * o.re);
  }

  mulScalar(v: number): C {
    return new C(this.re * v, this.im * v);
  }

  div(o: C): C {
    const d: number = o.re * o.re + o.im * o.im;
    return new C((this.re * o.re + this.im * o.im) / d, (this.im * o.re - this.re * o.im) / d);
  }

  conj(): C {
    return new C(this.re, -this.im);
  }

  abs(): number {
    return Math.hypot(this.re, this.im);
  }
}

export class LiveFilter {
  static bandLabels(): string[] {
    return BANDS.map((b: Band): string => b.label);
  }

  private _band: number = 0;
  private streams: Map<number, StreamState> = new Map<number, StreamState>();

  setBand(bandIndex: number): void {
    this._band = bandIndex > 0 && bandIndex < BANDS.length ? bandIndex : 0;
    this.streams.clear();
  }

  get band(): number {
    return this._band;
  }

  reset(): void {
    this.streams.clear();
  }

  apply(dataType: number, channel: number, vals: Float32Array, sampleRate: number): void {
    if (vals.length === 0 || this._band === 0) {
      return;
    }
    let st: StreamState | undefined = this.streams.get(dataType);
    if (st === undefined) {
      const created: StreamState = {
        band: 0, rate: 0, sections: [], zi0: [], channels: new Map<number, number[][]>()
      };
      this.streams.set(dataType, created);
      st = created;
    }
    if (st.band !== this._band || st.rate !== sampleRate) {
      st.sections = [];
      st.zi0 = [];
      st.channels.clear();
      st.band = this._band;
      st.rate = sampleRate;
      const designed: Biquad[] | null = LiveFilter.design(this._band, sampleRate);
      if (designed === null) {
        return;
      }
      st.sections = designed;
      let u: number = 1;
      for (const s of designed) {
        const g: number = (s.b0 + s.b1 + s.b2) / (1 + s.a1 + s.a2);
        const y: number = g * u;
        st.zi0.push([y - s.b0 * u, s.b2 * u - s.a2 * y]);
        u = y;
      }
    }
    if (st.sections.length === 0) {
      return;
    }
    let chState: number[][] | undefined = st.channels.get(channel);
    if (chState === undefined) {
      const created: number[][] = st.zi0.map((z: number[]): number[] => [z[0], z[1]]);
      st.channels.set(channel, created);
      chState = created;
    }
    for (let i = 0; i < vals.length; i++) {
      let x: number = vals[i];
      for (let s = 0; s < st.sections.length; s++) {
        const q: Biquad = st.sections[s];
        const z: number[] = chState[s];
        const y: number = q.b0 * x + z[0];
        z[0] = q.b1 * x - q.a1 * y + z[1];
        z[1] = q.b2 * x - q.a2 * y;
        x = y;
      }
      vals[i] = x;
    }
  }

  private static design(bandIndex: number, fs: number): Biquad[] | null {
    if (bandIndex <= 0 || bandIndex >= BANDS.length || fs <= 0) {
      return null;
    }
    const band: Band = BANDS[bandIndex];
    const lo: number = band.lo;
    const hi: number = band.hi;
    if (hi >= fs / 2) {
      return null;
    }
    const w1: number = 2 * fs * Math.tan((PI * lo) / fs);
    const w2: number = 2 * fs * Math.tan((PI * hi) / fs);
    const bw: number = w2 - w1;
    const wo: number = Math.sqrt(w1 * w2);
    const fs2: number = 2 * fs;

    const poles: C[] = [];
    const zeros: C[] = [];
    for (let k = 0; k < ORDER; k++) {
      const ang: number = (PI * (2 * k + 1 + ORDER)) / (2 * ORDER);
      const p: C = C.polar(1, ang);
      const mid: C = p.mulScalar(0.5 * bw);
      const disc: C = C.sqrtOf(mid.mul(mid).sub(C.real(wo * wo)));
      const sp1: C = mid.add(disc);
      const sp2: C = mid.sub(disc);
      poles.push(sp1.addScalar(fs2).div(C.real(fs2).sub(sp1)));
      poles.push(sp2.addScalar(fs2).div(C.real(fs2).sub(sp2)));
    }
    for (let k = 0; k < ORDER; k++) {
      zeros.push(C.real(1));
      zeros.push(C.real(-1));
    }
    const gain: C = C.real(Math.pow(bw, ORDER)).mulScalar(Math.pow(fs2, ORDER));
    let denom: C = C.real(1);
    for (let k = 0; k < ORDER; k++) {
      const ang: number = (PI * (2 * k + 1 + ORDER)) / (2 * ORDER);
      const p: C = C.polar(1, ang);
      const mid: C = p.mulScalar(0.5 * bw);
      const disc: C = C.sqrtOf(mid.mul(mid).sub(C.real(wo * wo)));
      denom = denom.mul(C.real(fs2).sub(mid.add(disc)).mul(C.real(fs2).sub(mid.sub(disc))));
    }
    const kz: number = gain.div(denom).re;

    const sections: Biquad[] = [];
    while (poles.length > 0) {
      const p: C = poles.pop() as C;
      const pc0: C = p.conj();
      let best: number = 0;
      for (let i = 1; i < poles.length; i++) {
        if (poles[i].sub(pc0).abs() < poles[best].sub(pc0).abs()) {
          best = i;
        }
      }
      const pc: C = poles.splice(best, 1)[0];
      const zpair: C[] = [];
      for (let j = 0; j < 2; j++) {
        let bz: number = 0;
        for (let i = 1; i < zeros.length; i++) {
          const d: number = Math.min(zeros[i].sub(p).abs(), zeros[i].sub(pc).abs());
          const db: number = Math.min(zeros[bz].sub(p).abs(), zeros[bz].sub(pc).abs());
          if (d < db) {
            bz = i;
          }
        }
        zpair.push(zeros.splice(bz, 1)[0]);
      }
      sections.push({
        b0: 1,
        b1: -zpair[0].add(zpair[1]).re,
        b2: zpair[0].mul(zpair[1]).re,
        a1: -p.add(pc).re,
        a2: p.mul(pc).re
      });
    }
    sections[0].b0 *= kz;
    sections[0].b1 *= kz;
    sections[0].b2 *= kz;
    return sections;
  }
}
