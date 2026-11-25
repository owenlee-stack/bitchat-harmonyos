/**
 * Orthographic globe projection and geohash zoom math for the 3D globe
 * picker (T067, US13).
 *
 * Port of the Android globe kernel (bitchat_android .../ui/globe/GlobeMath.kt):
 * the globe renders as a disc of radius R centered on screen; points project
 * around a view center (lat, lon). cosC < 0 marks the far side of the sphere.
 * The kernel stays pure ArkTS (no @ohos/@kit imports) so the host contract
 * runner can execute it unchanged.
 */

/** Result of projecting a lat/lon onto the view disc, in units of globe radius. */
export class GlobeProjection {
  readonly x: number;
  readonly y: number;
  /** Negative when the point is on the far side of the sphere. */
  readonly cosC: number;

  constructor(x: number, y: number, cosC: number) {
    this.x = x;
    this.y = y;
    this.cosC = cosC;
  }
}

/** Latitude/longitude pair in degrees. */
export class GlobeLatLng {
  readonly lat: number;
  readonly lon: number;

  constructor(lat: number, lon: number) {
    this.lat = lat;
    this.lon = lon;
  }
}

/**
 * Frame-local projector for prepared static geometry (Android
 * GlobeMath.PreparedProjector parity): center trig terms are computed once
 * and per-point results are written into caller-owned arrays without
 * allocating objects.
 */
export class GlobePreparedProjector {
  private readonly sinCenterLat: number;
  private readonly cosCenterLat: number;
  private readonly sinCenterLon: number;
  private readonly cosCenterLon: number;

  constructor(centerLatDeg: number, centerLonDeg: number) {
    this.sinCenterLat = Math.sin(GlobeMath.toRadians(centerLatDeg));
    this.cosCenterLat = Math.cos(GlobeMath.toRadians(centerLatDeg));
    this.sinCenterLon = Math.sin(GlobeMath.toRadians(centerLonDeg));
    this.cosCenterLon = Math.cos(GlobeMath.toRadians(centerLonDeg));
  }

  /**
   * Projects one prepared point. terms holds per-point sin(lat), cos(lat),
   * sin(lon), cos(lon) at termOffset; output x, y, cosC land in out at
   * outOffset.
   */
  project(terms: Float32Array, termOffset: number, out: Float32Array, outOffset: number): void {
    const sinLat: number = terms[termOffset];
    const cosLat: number = terms[termOffset + 1];
    const sinLon: number = terms[termOffset + 2];
    const cosLon: number = terms[termOffset + 3];
    const sinDeltaLon: number = sinLon * this.cosCenterLon - cosLon * this.sinCenterLon;
    const cosDeltaLon: number = cosLon * this.cosCenterLon + sinLon * this.sinCenterLon;
    out[outOffset] = cosLat * sinDeltaLon;
    out[outOffset + 1] = -(this.cosCenterLat * sinLat - this.sinCenterLat * cosLat * cosDeltaLon);
    out[outOffset + 2] = this.sinCenterLat * sinLat + this.cosCenterLat * cosLat * cosDeltaLon;
  }
}

export class GlobeMath {
  /** A cell is selectable once it spans this share of the screen's short side. */
  static readonly AUTO_PRECISION_CELL_FRACTION: number = 0.22;
  static readonly MIN_ZOOM: number = 1;
  static readonly MAX_ZOOM: number = 120000;
  static readonly MAX_PRECISION: number = 12;

  static toRadians(deg: number): number {
    return deg * Math.PI / 180;
  }

  static toDegrees(rad: number): number {
    return rad * 180 / Math.PI;
  }

  /**
   * Projects (lat, lon) onto the view disc of a globe centered at
   * (centerLat, centerLon). x/y are in units of globe radius with screen y
   * down; cosC is negative on the far side.
   */
  static projectRaw(latDeg: number, lonDeg: number,
    centerLatDeg: number, centerLonDeg: number): GlobeProjection {
    const phi: number = GlobeMath.toRadians(latDeg);
    const phi0: number = GlobeMath.toRadians(centerLatDeg);
    const dLambda: number = GlobeMath.toRadians(GlobeMath.normalizeLon(lonDeg - centerLonDeg));
    const cosC: number = Math.sin(phi0) * Math.sin(phi) + Math.cos(phi0) * Math.cos(phi) * Math.cos(dLambda);
    const x: number = Math.cos(phi) * Math.sin(dLambda);
    const y: number = -(Math.cos(phi0) * Math.sin(phi) - Math.sin(phi0) * Math.cos(phi) * Math.cos(dLambda));
    return new GlobeProjection(x, y, cosC);
  }

  /** Like projectRaw but null when the point is behind the limb. */
  static project(latDeg: number, lonDeg: number,
    centerLatDeg: number, centerLonDeg: number): GlobeProjection | null {
    const p: GlobeProjection = GlobeMath.projectRaw(latDeg, lonDeg, centerLatDeg, centerLonDeg);
    return p.cosC >= 0 ? p : null;
  }

  /**
   * Inverse projection: disc coordinates (units of radius, screen y down)
   * back to lat/lon. Null when the point lies outside the disc.
   */
  static unproject(x: number, y: number,
    centerLatDeg: number, centerLonDeg: number): GlobeLatLng | null {
    const rho: number = Math.sqrt(x * x + y * y);
    if (rho > 1) {
      return null;
    }
    const c: number = Math.asin(Math.min(1, Math.max(-1, rho)));
    const phi0: number = GlobeMath.toRadians(centerLatDeg);
    const sinC: number = Math.sin(c);
    const cosC: number = Math.cos(c);
    let lat: number;
    let lonOffset: number;
    if (rho < 1e-9) {
      lat = centerLatDeg;
      lonOffset = 0;
    } else {
      lat = GlobeMath.toDegrees(
        Math.asin(cosC * Math.sin(phi0) + (-y) * sinC * Math.cos(phi0) / rho));
      lonOffset = GlobeMath.toDegrees(
        Math.atan2(x * sinC, rho * Math.cos(phi0) * cosC - (-y) * Math.sin(phi0) * sinC));
    }
    return new GlobeLatLng(lat, GlobeMath.normalizeLon(centerLonDeg + lonOffset));
  }

  static normalizeLon(lon: number): number {
    let x: number = lon % 360;
    if (x > 180) {
      x -= 360;
    }
    if (x < -180) {
      x += 360;
    }
    return x;
  }

  /** Longitude span of a geohash cell in degrees. */
  static cellSpanLon(precision: number): number {
    return 360 / Math.pow(2, Math.ceil(5 * precision / 2));
  }

  /** Latitude span of a geohash cell in degrees. */
  static cellSpanLat(precision: number): number {
    return 180 / Math.pow(2, Math.floor(5 * precision / 2));
  }

  /**
   * Picks the geohash precision whose cells render at a comfortable on-screen
   * size for the current zoom: the largest precision whose cell spans at
   * least ~22% of the screen's smallest dimension.
   */
  static autoPrecision(globeRadiusPx: number, screenMinPx: number): number {
    const targetPx: number = screenMinPx * GlobeMath.AUTO_PRECISION_CELL_FRACTION;
    let best: number = 1;
    for (let p: number = 1; p <= GlobeMath.MAX_PRECISION; p++) {
      const spanPx: number =
        GlobeMath.cellSpanLat(p) * (Math.PI / 180) * globeRadiusPx;
      if (spanPx >= targetPx) {
        best = p;
      } else {
        break;
      }
    }
    return Math.min(GlobeMath.MAX_PRECISION, Math.max(1, best));
  }

  /** The zoom at which autoPrecision first reaches the given precision. */
  static thresholdZoomForPrecision(precision: number,
    baseRadiusPx: number, screenMinPx: number): number {
    const spanRad: number = GlobeMath.cellSpanLat(precision) * (Math.PI / 180);
    return (screenMinPx * GlobeMath.AUTO_PRECISION_CELL_FRACTION) / (spanRad * baseRadiusPx);
  }

  /**
   * Zoom factor (globe radius multiplier over the fit-to-screen base radius)
   * that frames a cell of the given precision nicely: the cell spans ~1/3 of
   * the screen.
   */
  static zoomForPrecision(precision: number,
    baseRadiusPx: number, screenMinPx: number): number {
    const spanRad: number = GlobeMath.cellSpanLat(precision) * (Math.PI / 180);
    const targetRadius: number = (screenMinPx / 3) / spanRad;
    const zoom: number = targetRadius / baseRadiusPx;
    return Math.min(GlobeMath.MAX_ZOOM, Math.max(GlobeMath.MIN_ZOOM, zoom));
  }
}
