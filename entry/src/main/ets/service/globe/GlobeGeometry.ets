/**
 * Disc-space geometry for the globe renderer (T067, US13).
 *
 * Port of the helpers inside the Android GlobeView.kt: splitting projected
 * geometry into front-facing runs, closing land fills along the horizon,
 * point-in-polygon / point-in-ring tests and viewport clipping (the 2D
 * rasterizer loses precision with path coordinates beyond ~32767px, which
 * happens at high globe zoom). Pure ArkTS: host-runnable.
 */
import { GlobeLatLng, GlobeMath } from './GlobeMath';

/** Plain screen-space 2D point. */
export class GlobeXY {
  readonly x: number;
  readonly y: number;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

/** A projected point in units of globe radius plus its facing flag. */
export class GlobeDiscPoint {
  readonly x: number;
  readonly y: number;
  readonly front: boolean;

  constructor(x: number, y: number, front: boolean) {
    this.x = x;
    this.y = y;
    this.front = front;
  }
}

/** Expanded viewport rect used to bound rasterizer coordinates. */
export class GlobeClipRect {
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;

  constructor(left: number, top: number, right: number, bottom: number) {
    this.left = left;
    this.top = top;
    this.right = right;
    this.bottom = bottom;
  }
}

/** Liang-Barsky output: the clipped segment endpoints. */
export class GlobeSegment {
  readonly x0: number;
  readonly y0: number;
  readonly x1: number;
  readonly y1: number;

  constructor(x0: number, y0: number, x1: number, y1: number) {
    this.x0 = x0;
    this.y0 = y0;
    this.x1 = x1;
    this.y1 = y1;
  }
}

export class GlobeGeometry {
  private static readonly LIMB_SEARCH_STEPS: number = 14;
  private static readonly MAX_ARC_STEPS: number = 64;

  /**
   * Interpolates between a behind-limb point and a front point to the
   * position where the segment crosses the unit disc edge.
   */
  private static limbPoint(behind: GlobeDiscPoint, front: GlobeDiscPoint): GlobeXY {
    let lo: number = 0;
    let hi: number = 1;
    for (let step: number = 0; step < GlobeGeometry.LIMB_SEARCH_STEPS; step++) {
      const t: number = (lo + hi) / 2;
      const x: number = behind.x + (front.x - behind.x) * t;
      const y: number = behind.y + (front.y - behind.y) * t;
      if (x * x + y * y < 1) {
        lo = t;
      } else {
        hi = t;
      }
    }
    const t: number = (lo + hi) / 2;
    return new GlobeXY(behind.x + (front.x - behind.x) * t,
      behind.y + (front.y - behind.y) * t);
  }

  /**
   * Splits a projected polygon into front-facing runs. Runs that touch the
   * limb are padded with the horizon intersection point so they can be
   * closed along the horizon. Pass closed = false for open polylines
   * (border lines).
   */
  static buildFrontRuns(pts: GlobeDiscPoint[], closed: boolean): GlobeXY[][] {
    const runs: GlobeXY[][] = [];
    if (pts.length === 0) {
      return runs;
    }
    const n: number = pts.length;
    let run: GlobeXY[] = [];
    let prev: GlobeDiscPoint | null = closed ? pts[n - 1] : null;
    for (let i: number = 0; i < n; i++) {
      const cur: GlobeDiscPoint = pts[i];
      const p: GlobeDiscPoint | null = prev;
      if (cur.front) {
        if (run.length === 0 && p !== null && !p.front) {
          run.push(GlobeGeometry.limbPoint(p, cur));
        }
        // Antimeridian wrap: consecutive front points can jump across the
        // whole disc when a polygon crosses +/-180 degrees - break the run
        // instead of drawing a chord through the view.
        if (run.length > 0) {
          const last: GlobeXY = run[run.length - 1];
          const dx: number = cur.x - last.x;
          const dy: number = cur.y - last.y;
          if (dx * dx + dy * dy > 1.2) {
            runs.push(run);
            run = [];
          }
        }
        run.push(new GlobeXY(cur.x, cur.y));
      } else {
        if (run.length > 0 && p !== null) {
          run.push(GlobeGeometry.limbPoint(p, cur));
          runs.push(run);
          run = [];
        }
      }
      prev = cur;
    }
    if (run.length > 0) {
      if (closed && runs.length > 0 && pts[0].front && pts[n - 1].front) {
        const merged: GlobeXY[] = run;
        for (let k: number = 0; k < runs[0].length; k++) {
          merged.push(runs[0][k]);
        }
        runs[0] = merged;
      } else {
        // A fully front-facing ring has no limb transition to terminate its
        // run; close it explicitly.
        if (closed && runs.length === 0 && pts[0].front && pts[n - 1].front) {
          run.push(run[0]);
        }
        runs.push(run);
      }
    }
    return runs;
  }

  /**
   * Builds a fill polygon for a projected ring by clamping back-facing
   * points onto the limb and inserting horizon arc steps between
   * consecutive limb points, approximating (polygon AND visible disc)
   * without self-intersecting chords.
   */
  static buildFillPolygon(pts: GlobeDiscPoint[], cx: number, cy: number, r: number): GlobeXY[] {
    const out: GlobeXY[] = [];
    let prevLimbAngle: number | null = null;
    let firstLimbAngle: number | null = null;
    for (let i: number = 0; i < pts.length; i++) {
      const p: GlobeDiscPoint = pts[i];
      if (p.front) {
        out.push(new GlobeXY(cx + p.x * r, cy + p.y * r));
        prevLimbAngle = null;
      } else {
        const len: number = Math.sqrt(p.x * p.x + p.y * p.y);
        let lx: number;
        let ly: number;
        if (len > 1e-6) {
          lx = p.x / len;
          ly = p.y / len;
        } else {
          lx = 0;
          ly = -1;
        }
        const ang: number = Math.atan2(ly, lx);
        const prevAng: number | null = prevLimbAngle;
        if (prevAng !== null) {
          GlobeGeometry.addArc(out, cx, cy, r, prevAng, ang);
        }
        if (firstLimbAngle === null) {
          firstLimbAngle = ang;
        }
        out.push(new GlobeXY(cx + lx * r, cy + ly * r));
        prevLimbAngle = ang;
      }
    }
    // Wrap-around arc when the ring ends and starts on the limb.
    const lastAng: number | null = prevLimbAngle;
    const firstAng: number | null = firstLimbAngle;
    if (lastAng !== null && firstAng !== null && pts.length > 0 && !pts[0].front) {
      GlobeGeometry.addArc(out, cx, cy, r, lastAng, firstAng);
    }
    return out;
  }

  private static addArc(out: GlobeXY[], cx: number, cy: number, r: number,
    from: number, to: number): void {
    let d: number = to - from;
    const twoPi: number = 2 * Math.PI;
    while (d > Math.PI) {
      d -= twoPi;
    }
    while (d < -Math.PI) {
      d += twoPi;
    }
    const steps: number = Math.min(GlobeGeometry.MAX_ARC_STEPS,
      Math.max(1, Math.trunc(Math.abs(d) / 0.04)));
    for (let s: number = 1; s < steps; s++) {
      const a: number = from + d * s / steps;
      out.push(new GlobeXY(cx + Math.cos(a) * r, cy + Math.sin(a) * r));
    }
  }

  /**
   * Point-in-ring test in geographic space (Android ringContainsLocation
   * parity): counts ring edges crossing the probe's meridian north of it,
   * following each edge the short way around so neither the +/-180 seam nor
   * the probe's antimeridian creates a false crossing. coords holds
   * interleaved (lat, lon) pairs.
   */
  static ringContainsLocation(coords: Float32Array, size: number,
    latitude: number, longitude: number): boolean {
    if (size < 3) {
      return false;
    }
    let inside: boolean = false;
    let previousIndex: number = size - 1;
    for (let index: number = 0; index < size; index++) {
      const startLat: number = coords[previousIndex * 2];
      const endLat: number = coords[index * 2];
      const startLon: number = coords[previousIndex * 2 + 1];
      const endLon: number = coords[index * 2 + 1];
      const start: number = GlobeMath.normalizeLon(startLon - longitude);
      // Unbounded on purpose: the end changes sign relative to the start
      // only when the edge crosses the probe meridian, never when it
      // crosses +/-180.
      const end: number = start + GlobeMath.normalizeLon(endLon - startLon);
      if ((start > 0) !== (end > 0)) {
        const t: number = start / (start - end);
        if (startLat + (endLat - startLat) * t > latitude) {
          inside = !inside;
        }
      }
      previousIndex = index;
    }
    return inside;
  }

  /** Even-odd point-in-polygon test in screen space. */
  static polygonContains(polygon: GlobeXY[], x: number, y: number): boolean {
    if (polygon.length < 3) {
      return false;
    }
    let inside: boolean = false;
    let previous: GlobeXY = polygon[polygon.length - 1];
    for (let i: number = 0; i < polygon.length; i++) {
      const current: GlobeXY = polygon[i];
      const crossesRay: boolean = (current.y > y) !== (previous.y > y);
      if (crossesRay) {
        const intersectionX: number = (previous.x - current.x) *
          (y - current.y) / (previous.y - current.y) + current.x;
        if (x < intersectionX) {
          inside = !inside;
        }
      }
      previous = current;
    }
    return inside;
  }

  /**
   * Orthographic projection can choose the wrong side of the horizon
   * closure for very large rings. Compare several visible points with the
   * original geographic ring and invert only when the opposite fill wins
   * clearly.
   */
  static projectedFillNeedsInversion(polygon: GlobeXY[], ringCoords: Float32Array,
    ringSize: number, cx: number, cy: number, r: number,
    centerLat: number, centerLon: number): boolean {
    const samples: GlobeXY[] = [
      new GlobeXY(0, 0),
      new GlobeXY(-0.5, 0),
      new GlobeXY(0.5, 0),
      new GlobeXY(0, -0.5),
      new GlobeXY(0, 0.5),
      new GlobeXY(-0.35, -0.35),
      new GlobeXY(0.35, -0.35),
      new GlobeXY(-0.35, 0.35),
      new GlobeXY(0.35, 0.35)
    ];
    let normalErrors: number = 0;
    let invertedErrors: number = 0;
    for (let i: number = 0; i < samples.length; i++) {
      const sample: GlobeXY = samples[i];
      const location: GlobeLatLng | null = GlobeMath.unproject(sample.x, sample.y,
        centerLat, centerLon);
      if (location === null) {
        continue;
      }
      const geographicInside: boolean = GlobeGeometry.ringContainsLocation(ringCoords, ringSize,
        location.lat, location.lon);
      const projectedInside: boolean = GlobeGeometry.polygonContains(polygon,
        cx + sample.x * r, cy + sample.y * r);
      if (projectedInside !== geographicInside) {
        normalErrors++;
      }
      if (!projectedInside !== geographicInside) {
        invertedErrors++;
      }
    }
    return invertedErrors < normalErrors;
  }

  /** Sutherland-Hodgman clip of a polygon to a viewport rect. */
  static clipPolygon(pts: GlobeXY[], rect: GlobeClipRect): GlobeXY[] {
    let out: GlobeXY[] = pts;
    out = GlobeGeometry.clipEdgeX(out, rect.left, true);
    out = GlobeGeometry.clipEdgeX(out, rect.right, false);
    out = GlobeGeometry.clipEdgeY(out, rect.top, true);
    out = GlobeGeometry.clipEdgeY(out, rect.bottom, false);
    return out;
  }

  private static clipEdgeX(input: GlobeXY[], boundary: number, keepGreater: boolean): GlobeXY[] {
    const result: GlobeXY[] = [];
    if (input.length === 0) {
      return result;
    }
    let s: GlobeXY = input[input.length - 1];
    for (let i: number = 0; i < input.length; i++) {
      const e: GlobeXY = input[i];
      const eIn: boolean = keepGreater ? e.x >= boundary : e.x <= boundary;
      const sIn: boolean = keepGreater ? s.x >= boundary : s.x <= boundary;
      if (eIn) {
        if (!sIn) {
          const t: number = (boundary - s.x) / (e.x - s.x);
          result.push(new GlobeXY(boundary, s.y + t * (e.y - s.y)));
        }
        result.push(e);
      } else if (sIn) {
        const t: number = (boundary - s.x) / (e.x - s.x);
        result.push(new GlobeXY(boundary, s.y + t * (e.y - s.y)));
      }
      s = e;
    }
    return result;
  }

  private static clipEdgeY(input: GlobeXY[], boundary: number, keepGreater: boolean): GlobeXY[] {
    const result: GlobeXY[] = [];
    if (input.length === 0) {
      return result;
    }
    let s: GlobeXY = input[input.length - 1];
    for (let i: number = 0; i < input.length; i++) {
      const e: GlobeXY = input[i];
      const eIn: boolean = keepGreater ? e.y >= boundary : e.y <= boundary;
      const sIn: boolean = keepGreater ? s.y >= boundary : s.y <= boundary;
      if (eIn) {
        if (!sIn) {
          const t: number = (boundary - s.y) / (e.y - s.y);
          result.push(new GlobeXY(s.x + t * (e.x - s.x), boundary));
        }
        result.push(e);
      } else if (sIn) {
        const t: number = (boundary - s.y) / (e.y - s.y);
        result.push(new GlobeXY(s.x + t * (e.x - s.x), boundary));
      }
      s = e;
    }
    return result;
  }

  /** Liang-Barsky clip of a segment to the rect; null when fully outside. */
  static clipSegment(x0: number, y0: number, x1: number, y1: number,
    rect: GlobeClipRect): GlobeSegment | null {
    const dx: number = x1 - x0;
    const dy: number = y1 - y0;
    let u1: number = 0;
    let u2: number = 1;
    // Liang-Barsky edge tests, unrolled per edge.
    const tests: number[][] = [
      [-dx, x0 - rect.left],
      [dx, rect.right - x0],
      [-dy, y0 - rect.top],
      [dy, rect.bottom - y0]
    ];
    for (let i: number = 0; i < tests.length; i++) {
      const p: number = tests[i][0];
      const q: number = tests[i][1];
      if (p === 0) {
        if (q < 0) {
          return null;
        }
        continue;
      }
      const ratio: number = q / p;
      if (p < 0) {
        if (ratio > u2) {
          return null;
        }
        if (ratio > u1) {
          u1 = ratio;
        }
      } else {
        if (ratio < u1) {
          return null;
        }
        if (ratio < u2) {
          u2 = ratio;
        }
      }
    }
    return new GlobeSegment(x0 + u1 * dx, y0 + u1 * dy, x0 + u2 * dx, y0 + u2 * dy);
  }
}
