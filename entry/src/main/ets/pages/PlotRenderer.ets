import { SpectrumResult } from '../dsp/SpectrumCompute';

export const CHANNEL_COLORS: string[] = [
  '#1f77b4', '#ff7f0e', '#2ca02c', '#d62728', '#9467bd', '#8c564b', '#e377c2', '#7f7f7f'
];

const TITLE_HEIGHT: number = 14;
const AXIS_HEIGHT: number = 14;
const INSET: number = 2;
const SIDE_TEXT_WIDTH: number = 76;

function curveColor(index: number): string {
  return CHANNEL_COLORS[((index % CHANNEL_COLORS.length) + CHANNEL_COLORS.length) %
    CHANNEL_COLORS.length];
}

export function drawWaveform(ctx: CanvasRenderingContext2D, x: number, y: number, w: number,
                             h: number, channels: Float32Array[], colorBase: number,
                             title: string, sideText: string, sideColor: string,
                             yRange: number[]): void {
  ctx.fillStyle = '#1C1C1E';
  ctx.fillRect(x, y, w, h);
  const hasTitle: boolean = title.length > 0;
  const titleH: number = hasTitle ? TITLE_HEIGHT : 0;
  const plotH: number = Math.max(1, h - titleH);
  const top: number = y + titleH;
  if (hasTitle) {
    ctx.fillStyle = '#C8C8CC';
    ctx.font = '11px sans-serif';
    ctx.fillText(title, x + 6, y + 11);
  }

  let min: number = 0;
  let max: number = 0;
  if (yRange.length === 2) {
    min = yRange[0];
    max = yRange[1];
  } else {
    min = Number.MAX_VALUE;
    max = -Number.MAX_VALUE;
    for (const data of channels) {
      for (let i = 0; i < data.length; i++) {
        const v: number = data[i];
        if (v < min) {
          min = v;
        }
        if (v > max) {
          max = v;
        }
      }
    }
    if (min === Number.MAX_VALUE || max === -Number.MAX_VALUE) {
      min = -1;
      max = 1;
    }
    if (min === max) {
      min -= 1;
      max += 1;
    }
    const margin: number = (max - min) * 0.1;
    min -= margin;
    max += margin;
  }
  const span: number = max - min !== 0 ? max - min : 1;

  const toY = (v: number): number => top + plotH - 1 - ((v - min) / span) * (plotH - 2);
  const centerY: number = Math.min(top + plotH - 1, Math.max(top + 1, toY(0)));
  ctx.strokeStyle = '#444444';
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(x, centerY);
  ctx.lineTo(x + w, centerY);
  ctx.stroke();

  const plotW: number = sideText.length > 0 ? Math.max(1, w - SIDE_TEXT_WIDTH) : w;
  for (let c = 0; c < channels.length; c++) {
    const data: Float32Array = channels[c];
    const len: number = data.length;
    if (len === 0 || plotW <= 1) {
      continue;
    }
    ctx.strokeStyle = curveColor(colorBase + c);
    ctx.beginPath();
    for (let px = 0; px < plotW; px++) {
      const idx: number = Math.min(len - 1, Math.floor((px * len) / plotW));
      const py: number = toY(data[idx]);
      if (px === 0) {
        ctx.moveTo(x, py);
      } else {
        ctx.lineTo(x + px, py);
      }
    }
    ctx.stroke();
  }

  if (sideText.length > 0) {
    ctx.fillStyle = sideColor;
    ctx.font = '10px sans-serif';
    ctx.fillText(sideText, x + w - SIDE_TEXT_WIDTH + 4, top + plotH / 2);
  }
}

export function drawSpectrum(ctx: CanvasRenderingContext2D, x: number, y: number, w: number,
                             h: number, spectrum: SpectrumResult | null, colorPin: number,
                             labels: string[], placeholder: string): void {
  ctx.fillStyle = '#1C1C1E';
  ctx.fillRect(x, y, w, h);
  const plotL: number = x + INSET;
  const plotT: number = y + INSET;
  const plotR: number = Math.max(plotL + 1, x + w - INSET);
  const plotB: number = Math.max(plotT + 1, y + h - AXIS_HEIGHT);
  const plotW: number = plotR - plotL;
  const plotH: number = plotB - plotT;
  ctx.strokeStyle = '#5A5A5A';
  ctx.lineWidth = 1;
  ctx.strokeRect(plotL, plotT, plotW - 1, plotH - 1);

  const hasData: boolean = spectrum !== null && spectrum.freqs.length >= 2 &&
    spectrum.mags.length > 0;
  const fMax: number = hasData && spectrum !== null ?
    spectrum.freqs[spectrum.freqs.length - 1] : 0;
  if (!hasData || fMax <= 0 || spectrum === null) {
    ctx.fillStyle = '#969696';
    ctx.font = '11px sans-serif';
    ctx.fillText(placeholder, plotL + plotW / 2 - placeholder.length * 3,
      (plotT + plotB) / 2 + 3);
    return;
  }

  let peak: number = 0;
  for (const row of spectrum.mags) {
    for (let i = 0; i < row.length; i++) {
      if (row[i] > peak) {
        peak = row[i];
      }
    }
  }
  const yMax: number = peak > 0 ? peak * 1.1 : 1;

  for (let ch = 0; ch < spectrum.mags.length; ch++) {
    const row: Float32Array = spectrum.mags[ch];
    const count: number = Math.min(row.length, spectrum.freqs.length);
    const color: string = curveColor(colorPin >= 0 ? colorPin : ch);
    ctx.strokeStyle = color;
    ctx.beginPath();
    for (let i = 0; i < count; i++) {
      const px: number = plotL + (spectrum.freqs[i] / fMax) * (plotW - 1);
      const py: number = plotB - 1 - (row[i] / yMax) * (plotH - 2);
      if (i === 0) {
        ctx.moveTo(px, py);
      } else {
        ctx.lineTo(px, py);
      }
    }
    ctx.stroke();
    ctx.fillStyle = color;
    ctx.font = '10px sans-serif';
    const label: string = ch < labels.length ? labels[ch] : 'ch' + ch.toString();
    ctx.fillText(label, plotL + 4, plotT + 12 + ch * 13);
  }

  ctx.fillStyle = '#969696';
  ctx.font = '10px sans-serif';
  ctx.fillText('0', plotL + 2, y + h - 3);
  const fText: string = fMax.toFixed(1) + ' Hz';
  ctx.fillText(fText, plotR - 2 - fText.length * 5.5, y + h - 3);
}
