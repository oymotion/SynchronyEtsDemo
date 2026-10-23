const PI: number = 3.14159265358979323846;

export interface SpectrumResult {
  freqs: Float32Array;
  mags: Float32Array[];
}

function fft(re: Float64Array, im: Float64Array, n: number): void {
  let j: number = 0;
  for (let i = 1; i < n; i++) {
    let bit: number = n >> 1;
    while ((j & bit) !== 0) {
      j ^= bit;
      bit >>= 1;
    }
    j ^= bit;
    if (i < j) {
      const tr: number = re[i];
      re[i] = re[j];
      re[j] = tr;
      const ti: number = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang: number = (-2 * PI) / len;
    const wlenR: number = Math.cos(ang);
    const wlenI: number = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let wr: number = 1;
      let wi: number = 0;
      for (let k = 0; k < len / 2; k++) {
        const ur: number = re[i + k];
        const ui: number = im[i + k];
        const vr: number = re[i + k + len / 2] * wr - im[i + k + len / 2] * wi;
        const vi: number = re[i + k + len / 2] * wi + im[i + k + len / 2] * wr;
        re[i + k] = ur + vr;
        im[i + k] = ui + vi;
        re[i + k + len / 2] = ur - vr;
        im[i + k + len / 2] = ui - vi;
        const nwr: number = wr * wlenR - wi * wlenI;
        wi = wr * wlenI + wi * wlenR;
        wr = nwr;
      }
    }
  }
}

export function computeSpectrum(channels: Float32Array[], rate: number): SpectrumResult | null {
  if (channels.length === 0 || rate <= 0) {
    return null;
  }
  const n: number = channels[0].length;
  if (n < 16) {
    return null;
  }
  let nfft: number = 1;
  while (nfft < n) {
    nfft <<= 1;
  }
  const win: Float64Array = new Float64Array(n);
  let winSum: number = 0;
  for (let i = 0; i < n; i++) {
    win[i] = 0.5 - 0.5 * Math.cos((2 * PI * i) / (n - 1));
    winSum += win[i];
  }
  const freqs: Float32Array = new Float32Array(nfft / 2 + 1);
  for (let k = 0; k <= nfft / 2; k++) {
    freqs[k] = (k * rate) / nfft;
  }
  const re: Float64Array = new Float64Array(nfft);
  const im: Float64Array = new Float64Array(nfft);
  const mags: Float32Array[] = [];
  for (const ch of channels) {
    const m: number = Math.min(n, ch.length);
    re.fill(0);
    im.fill(0);
    for (let i = 0; i < m; i++) {
      re[i] = ch[i] * win[i];
    }
    fft(re, im, nfft);
    const scale: number = 2 / Math.max(winSum, 1e-12);
    const row: Float32Array = new Float32Array(nfft / 2 + 1);
    for (let k = 0; k <= nfft / 2; k++) {
      row[k] = scale * Math.hypot(re[k], im[k]);
    }
    mags.push(row);
  }
  const result: SpectrumResult = { freqs: freqs, mags: mags };
  return result;
}
