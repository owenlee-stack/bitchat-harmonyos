/**
 * Smooth pan-and-zoom flight path for the globe picker (T067, US13).
 *
 * Port of the Android GlobeFlight.kt: the curve from van Wijk and Nuij,
 * "Smooth and efficient zooming and panning" (behind d3-zoom and Mapbox
 * flyTo). It keeps on-screen motion even when the zoom changes by orders of
 * magnitude: pan while zoomed out, zoom in while nearly on target.
 *
 * distance is the arc between the start and end centers in radians; widths
 * are the angular span visible across the screen (screen size over globe
 * radius) at each end. Pure ArkTS: host-runnable.
 */
import { GlobeLatLng, GlobeMath } from './GlobeMath';

/** One sample of the flight curve: distance fraction and visible width. */
export class GlobeFlightSample {
  readonly fraction: number;
  readonly width: number;

  constructor(fraction: number, width: number) {
    this.fraction = fraction;
    this.width = width;
  }
}

export class GlobeFlight {
  private readonly distance: number;
  private readonly startWidth: number;
  private readonly endWidth: number;
  private readonly rho: number;
  private readonly panning: boolean;
  private readonly r0: number;
  private readonly length: number;

  constructor(distance: number, startWidth: number, endWidth: number, rho: number = GlobeFlight.RHO) {
    this.distance = distance;
    this.startWidth = startWidth;
    this.endWidth = endWidth;
    this.rho = rho;
    this.panning = distance > GlobeFlight.EPSILON;
    if (!this.panning) {
      this.r0 = 0;
      this.length = Math.log(endWidth / startWidth) / rho;
    } else {
      const rho2: number = rho * rho;
      const rho4: number = rho2 * rho2;
      const d2: number = distance * distance;
      const b0: number = (endWidth * endWidth - startWidth * startWidth + rho4 * d2) /
        (2 * startWidth * rho2 * distance);
      const b1: number = (endWidth * endWidth - startWidth * startWidth - rho4 * d2) /
        (2 * endWidth * rho2 * distance);
      // -asinh(b): the direct form ln(sqrt(b^2+1)-b) cancels to ln(0) when b
      // is large, which a zoom-out over a tiny arc produces.
      this.r0 = -GlobeFlight.asinh(b0);
      const r1: number = -GlobeFlight.asinh(b1);
      this.length = (r1 - this.r0) / rho;
    }
  }

  /** d3's default: how strongly the path zooms out to travel. */
  static readonly RHO: number = 1.414;
  /** Arcs shorter than this (d3's threshold) are zoom-only. */
  private static readonly EPSILON: number = 1e-6;

  /** Path length in the curve's own units; longer flights take longer. */
  get pathLength(): number {
    return Math.abs(this.length);
  }

  /** At progress t in 0..1: the fraction of distance covered and the visible width. */
  at(t: number): GlobeFlightSample {
    if (t >= 1) {
      return new GlobeFlightSample(1, this.endWidth);
    }
    const s: number = t * this.length;
    if (!this.panning) {
      return new GlobeFlightSample(t, this.startWidth * Math.exp(this.rho * s));
    }
    const coshR0: number = Math.cosh(this.r0);
    // The curve's position is w0/rho^2 * (...); dividing by distance as well
    // yields the fraction covered.
    const fraction: number = this.startWidth / (this.rho * this.rho * this.distance) *
      (coshR0 * Math.tanh(this.rho * s + this.r0) - Math.sinh(this.r0));
    const w: number = this.startWidth * coshR0 / Math.cosh(this.rho * s + this.r0);
    return new GlobeFlightSample(Math.min(1, Math.max(0, fraction)), w);
  }

  /** Great-circle angle between two points, radians. */
  static arc(lat0: number, lon0: number, lat1: number, lon1: number): number {
    const a: number[] = GlobeFlight.unit(lat0, lon0);
    const b: number[] = GlobeFlight.unit(lat1, lon1);
    const dot: number = Math.min(1, Math.max(-1, a[0] * b[0] + a[1] * b[1] + a[2] * b[2]));
    return Math.acos(dot);
  }

  /** Point a fraction of the way along the great circle; (lat, lon) degrees. */
  static slerp(lat0: number, lon0: number, lat1: number, lon1: number,
    fraction: number): GlobeLatLng {
    const a: number[] = GlobeFlight.unit(lat0, lon0);
    const b: number[] = GlobeFlight.unit(lat1, lon1);
    const dot: number = Math.min(1, Math.max(-1, a[0] * b[0] + a[1] * b[1] + a[2] * b[2]));
    const omega: number = Math.acos(dot);
    const sinOmega: number = Math.sin(omega);
    if (sinOmega < 1e-6) {
      // Same point or exact antipodes: no unique great circle, so
      // interpolate in degrees.
      const dLon: number = GlobeMath.normalizeLon(lon1 - lon0);
      return new GlobeLatLng(lat0 + (lat1 - lat0) * fraction,
        GlobeMath.normalizeLon(lon0 + dLon * fraction));
    }
    const wa: number = Math.sin((1 - fraction) * omega) / sinOmega;
    const wb: number = Math.sin(fraction * omega) / sinOmega;
    const x: number = wa * a[0] + wb * b[0];
    const y: number = wa * a[1] + wb * b[1];
    const z: number = wa * a[2] + wb * b[2];
    return new GlobeLatLng(
      GlobeMath.toDegrees(Math.asin(Math.min(1, Math.max(-1, z)))),
      GlobeMath.toDegrees(Math.atan2(y, x)));
  }

  private static asinh(x: number): number {
    return Math.log(x + Math.sqrt(x * x + 1));
  }

  private static unit(latDeg: number, lonDeg: number): number[] {
    const lat: number = GlobeMath.toRadians(latDeg);
    const lon: number = GlobeMath.toRadians(lonDeg);
    return [Math.cos(lat) * Math.cos(lon), Math.cos(lat) * Math.sin(lon), Math.sin(lat)];
  }
}
