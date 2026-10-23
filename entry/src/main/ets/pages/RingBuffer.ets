export class RingBuffer {
  channelCount: number = 0;
  length: number = 0;
  private data: Float32Array[] = [];
  private head: number = 0;

  ensureSize(channelCount: number, length: number): void {
    const len: number = Math.max(1, Math.round(length));
    if (this.channelCount === channelCount && this.length === len) {
      return;
    }
    this.channelCount = channelCount;
    this.length = len;
    this.data = [];
    for (let ch = 0; ch < channelCount; ch++) {
      this.data.push(new Float32Array(len));
    }
    this.head = 0;
  }

  appendBatch(channelValues: Float32Array[]): void {
    if (channelValues.length === 0 || this.length === 0) {
      return;
    }
    const count: number = channelValues[0].length;
    for (let i = 0; i < count; i++) {
      for (let ch = 0; ch < this.channelCount; ch++) {
        if (ch < this.data.length) {
          const vals: Float32Array = channelValues[ch];
          this.data[ch][this.head] = i < vals.length ? vals[i] : 0;
        }
      }
      this.head = (this.head + 1) % this.length;
    }
  }

  getChannel(ch: number): Float32Array {
    if (ch < 0 || ch >= this.data.length || this.length === 0) {
      return new Float32Array(0);
    }
    const buf: Float32Array = this.data[ch];
    const out: Float32Array = new Float32Array(this.length);
    for (let i = 0; i < this.length; i++) {
      out[i] = buf[(this.head + i) % this.length];
    }
    return out;
  }

  getAllChannels(): Float32Array[] {
    const out: Float32Array[] = [];
    for (let ch = 0; ch < this.channelCount; ch++) {
      out.push(this.getChannel(ch));
    }
    return out;
  }

  latest(ch: number): number {
    if (ch < 0 || ch >= this.data.length || this.length === 0) {
      return 0;
    }
    return this.data[ch][(this.head + this.length - 1) % this.length];
  }

  clear(): void {
    for (const buf of this.data) {
      buf.fill(0);
    }
    this.head = 0;
  }
}
