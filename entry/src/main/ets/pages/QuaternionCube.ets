const VERTICES: number[][] = [
  [-1, -1, -1],
  [1, -1, -1],
  [1, 1, -1],
  [-1, 1, -1],
  [-1, -1, 1],
  [1, -1, 1],
  [1, 1, 1],
  [-1, 1, 1]
];

const FACES: number[][] = [
  [0, 1, 2, 3],
  [4, 5, 6, 7],
  [0, 1, 5, 4],
  [2, 3, 7, 6],
  [0, 3, 7, 4],
  [1, 2, 6, 5]
];

const FACE_COLORS: string[] = [
  '#00b4b4', '#c83cc8', '#dcc828', '#c83c3c', '#3ca03c', '#3c64dc'
];

const AXES: number[][] = [
  [1.5, 0, 0],
  [0, 1.5, 0],
  [0, 0, 1.5]
];

const AXIS_COLORS: string[] = ['#dc3c3c', '#3cc83c', '#5078ff'];

const CAMERA_DIST: number = 4.5;

export function drawCube(ctx: CanvasRenderingContext2D, x: number, y: number, w: number,
                         h: number, quat: number[] | null, placeholder: string): void {
  ctx.fillStyle = '#1C1C1E';
  ctx.fillRect(x, y, w, h);
  if (quat === null || quat.length < 4 || w <= 1) {
    ctx.fillStyle = '#969696';
    ctx.font = '13px sans-serif';
    ctx.fillText(placeholder, x + w / 2 - placeholder.length * 3.5, y + h / 2 + 4);
    return;
  }

  let qw: number = quat[0];
  let qx: number = quat[1];
  let qy: number = quat[2];
  let qz: number = quat[3];
  const norm: number = Math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz);
  if (norm <= 0) {
    ctx.fillStyle = '#969696';
    ctx.font = '13px sans-serif';
    ctx.fillText(placeholder, x + w / 2 - placeholder.length * 3.5, y + h / 2 + 4);
    return;
  }
  qw /= norm;
  qx /= norm;
  qy /= norm;
  qz /= norm;

  const r: number[][] = [
    [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qw * qz), 2 * (qx * qz + qw * qy)],
    [2 * (qx * qy + qw * qz), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qw * qx)],
    [2 * (qx * qz - qw * qy), 2 * (qy * qz + qw * qx), 1 - 2 * (qx * qx + qy * qy)]
  ];

  const scale: number = Math.min(w, h) * 0.28;
  const cx: number = x + w / 2;
  const cy: number = y + h / 2;

  const rotate = (v: number[]): number[] => {
    const out: number[] = [];
    for (const row of r) {
      out.push(row[0] * v[0] + row[1] * v[1] + row[2] * v[2]);
    }
    return out;
  };
  const project = (v: number[]): number[] => {
    const persp: number = CAMERA_DIST / (CAMERA_DIST + v[2]);
    return [cx + v[0] * scale * persp, cy - v[1] * scale * persp];
  };

  const rotated: number[][] = [];
  for (const v of VERTICES) {
    rotated.push(rotate(v));
  }

  const order: number[] = [];
  for (let i = 0; i < FACES.length; i++) {
    order.push(i);
  }
  order.sort((a: number, b: number): number => {
    let za: number = 0;
    for (const k of FACES[a]) {
      za += rotated[k][2];
    }
    let zb: number = 0;
    for (const k of FACES[b]) {
      zb += rotated[k][2];
    }
    return zb - za;
  });

  ctx.lineWidth = 1;
  for (const f of order) {
    ctx.fillStyle = FACE_COLORS[f];
    ctx.strokeStyle = '#141414';
    ctx.beginPath();
    const face: number[] = FACES[f];
    for (let i = 0; i < face.length; i++) {
      const p: number[] = project(rotated[face[i]]);
      if (i === 0) {
        ctx.moveTo(p[0], p[1]);
      } else {
        ctx.lineTo(p[0], p[1]);
      }
    }
    ctx.closePath();
    ctx.fill();
    ctx.stroke();
  }

  const origin: number[] = project(rotate([0, 0, 0]));
  ctx.lineWidth = 2;
  for (let a = 0; a < AXES.length; a++) {
    const tip: number[] = project(rotate(AXES[a]));
    ctx.strokeStyle = AXIS_COLORS[a];
    ctx.beginPath();
    ctx.moveTo(origin[0], origin[1]);
    ctx.lineTo(tip[0], tip[1]);
    ctx.stroke();
  }
}
