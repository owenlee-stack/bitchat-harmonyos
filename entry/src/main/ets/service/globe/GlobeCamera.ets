/**
 * Hoisted camera state for the interactive 3D globe (T067, US13).
 *
 * Port of the Android GlobeState.kt minus the Compose/coroutine coupling:
 * view center (double precision - at deep zoom one float step of latitude
 * spans several pixels), zoom, geohash precision and the current selection.
 * Mutation funnels through this class so rendering, gestures and buttons
 * stay in sync; the animation loop lives in the page, driving the pure
 * [GlobeFlightPlan] samples produced here. Pure ArkTS: host-runnable.
 */
import { Geohash } from '../nostr/GeohashService';
import { GlobeLatLng, GlobeMath } from './GlobeMath';
import { GlobeFlight, GlobeFlightSample } from './GlobeFlight';

/** One animation frame of a flight: camera center and zoom. */
export class GlobeCameraSample {
  readonly lat: number;
  readonly lon: number;
  readonly zoom: number;

  constructor(lat: number, lon: number, zoom: number) {
    this.lat = lat;
    this.lon = lon;
    this.zoom = zoom;
  }
}

/**
 * A precomputed pan/zoom animation (Android GlobeState.animateTo parity):
 * a large zoom change flies along [GlobeFlight] so on-screen motion stays
 * even and takes longer the further it travels; [durationMs] is then a
 * minimum. Precision follows the zoom on the way and lands on the target
 * precision at the end.
 */
export class GlobeFlightPlan {
  readonly startLat: number;
  readonly startLon: number;
  readonly startZoom: number;
  readonly endLat: number;
  readonly endLon: number;
  readonly endZoom: number;
  readonly endPrecision: number | null;
  readonly durationMs: number;
  private readonly dLon: number;
  private readonly zoomRatio: number;
  private readonly zoomFloor: number;
  private readonly flight: GlobeFlight | null;
  private readonly baseRadiusPx: number;
  private readonly screenMinPx: number;

  constructor(startLat: number, startLon: number, startZoom: number,
    endLat: number, endLon: number, endZoom: number,
    endPrecision: number | null, durationMs: number,
    dLon: number, zoomFloor: number, flight: GlobeFlight | null,
    baseRadiusPx: number, screenMinPx: number) {
    this.startLat = startLat;
    this.startLon = startLon;
    this.startZoom = startZoom;
    this.endLat = endLat;
    this.endLon = endLon;
    this.endZoom = endZoom;
    this.endPrecision = endPrecision;
    this.durationMs = durationMs;
    this.dLon = dLon;
    this.zoomRatio = endZoom / startZoom;
    this.zoomFloor = zoomFloor;
    this.flight = flight;
    this.baseRadiusPx = baseRadiusPx;
    this.screenMinPx = screenMinPx;
  }

  /** Camera state at progress t in 0..1 (easing is applied by the caller). */
  sample(t: number): GlobeCameraSample {
    const flight: GlobeFlight | null = this.flight;
    if (flight !== null) {
      const sample: GlobeFlightSample = flight.at(t);
      const location: GlobeLatLng = GlobeFlight.slerp(this.startLat, this.startLon,
        this.endLat, this.endLon, sample.fraction);
      const zoom: number = this.zoomForWidth(sample.width);
      return new GlobeCameraSample(
        Math.min(GlobeCamera.MAX_LAT, Math.max(GlobeCamera.MIN_LAT, location.lat)),
        location.lon, zoom);
    }
    const lat: number = this.startLat + (this.endLat - this.startLat) * t;
    const lon: number = GlobeMath.normalizeLon(this.startLon + this.dLon * t);
    // Exponential interpolation feels natural for small zoom changes.
    const zoom: number = this.startZoom * Math.pow(this.zoomRatio, t);
    return new GlobeCameraSample(
      Math.min(GlobeCamera.MAX_LAT, Math.max(GlobeCamera.MIN_LAT, lat)), lon, zoom);
  }

  private zoomForWidth(width: number): number {
    const zoom: number = this.screenMinPx / (width * this.baseRadiusPx);
    return Math.min(GlobeMath.MAX_ZOOM, Math.max(this.zoomFloor, zoom));
  }
}

export class GlobeCamera {
  /** Close to the projection limit so polar geohash cells remain selectable. */
  static readonly MIN_LAT: number = -89;
  static readonly MAX_LAT: number = 89;
  /** Where the opening rotation's zoom-in starts: a little smaller than the whole globe. */
  static readonly INTRO_START_ZOOM: number = 0.72;
  /** How far toward the precision-2 threshold the opening rotation zooms. */
  static readonly INTRO_END_THRESHOLD_FRACTION: number = 0.8;
  /** Zoom within this fraction of the minimum already counts as the whole globe. */
  static readonly WHOLE_GLOBE_ZOOM_TOLERANCE: number = 0.01;
  /** Zoom changes beyond this factor fly along GlobeFlight; smaller ones glide. */
  static readonly FLIGHT_ZOOM_RATIO: number = 1.5;
  private static readonly FLIGHT_MS_PER_UNIT: number = 230;
  private static readonly MAX_FLIGHT_MS: number = 2200;

  centerLat: number = 0;
  centerLon: number = 0;
  zoom: number = 1;
  precision: number = 1;
  baseRadiusPx: number = 0;
  screenMinPx: number = 0;
  selectedGeohash: string = '';

  /**
   * Android GlobeState constructor parity: the zoomed-out opening starts
   * turned away from the target and slightly smaller than the whole globe.
   */
  initialize(targetLat: number, targetLon: number, initialPrecision: number,
    startZoomedOut: boolean): void {
    this.centerLat = startZoomedOut ? targetLat * 0.4 : targetLat;
    this.centerLon = startZoomedOut ? GlobeMath.normalizeLon(targetLon - 70) : targetLon;
    this.zoom = startZoomedOut ? GlobeCamera.INTRO_START_ZOOM : 1;
    this.precision = Math.min(GlobeMath.MAX_PRECISION, Math.max(1, initialPrecision));
    this.syncSelection();
  }

  setViewport(baseRadiusPx: number, screenMinPx: number): void {
    if (baseRadiusPx <= 0 || screenMinPx <= 0) {
      return;
    }
    this.baseRadiusPx = baseRadiusPx;
    this.screenMinPx = screenMinPx;
    this.syncSelection();
  }

  get globeRadiusPx(): number {
    return this.baseRadiusPx * this.zoom;
  }

  /** Direct rotation from drag gestures; deltas in screen px. */
  rotateBy(dxPx: number, dyPx: number): void {
    const radius: number = this.globeRadiusPx;
    if (radius <= 0) {
      return;
    }
    const degPerPx: number = 180 / (Math.PI * radius);
    this.centerLon = GlobeMath.normalizeLon(this.centerLon - dxPx * degPerPx);
    this.centerLat = Math.min(GlobeCamera.MAX_LAT,
      Math.max(GlobeCamera.MIN_LAT, this.centerLat + dyPx * degPerPx));
    this.syncSelection();
  }

  /** Continuous zoom from pinch gestures; precision follows automatically. */
  zoomBy(factor: number): void {
    if (factor === 1) {
      return;
    }
    // An interrupted intro can leave the globe below the minimum; continue
    // from there rather than snapping up, while never pinching further out
    // than the current size.
    this.zoom = Math.min(GlobeMath.MAX_ZOOM,
      Math.max(Math.min(GlobeMath.MIN_ZOOM, this.zoom), this.zoom * factor));
    this.syncPrecisionFromZoom();
    this.syncSelection();
  }

  syncPrecisionFromZoom(): void {
    if (this.baseRadiusPx <= 0) {
      return;
    }
    this.precision = GlobeMath.autoPrecision(this.globeRadiusPx, this.screenMinPx);
  }

  /**
   * Where the opening rotation lands: zoomed in toward the region, but kept
   * a margin below the zoom at which two-letter cells take over, so the
   * selection stays at level 1.
   */
  introEndZoom(): number {
    return GlobeMath.thresholdZoomForPrecision(2, this.baseRadiusPx, this.screenMinPx) *
      GlobeCamera.INTRO_END_THRESHOLD_FRACTION;
  }

  /**
   * Whether - can widen the view. Level 1 spans a range of zooms, so it can
   * still pull back to the whole globe without changing precision.
   */
  get canZoomOut(): boolean {
    return this.precision > 1 ||
      this.zoom > GlobeMath.MIN_ZOOM * (1 + GlobeCamera.WHOLE_GLOBE_ZOOM_TOLERANCE);
  }

  /** Angular span across the screen's short side at the given zoom, radians. */
  visibleWidth(zoomValue: number): number {
    return this.screenMinPx / (this.baseRadiusPx * zoomValue);
  }

  /**
   * Precomputes the animation to a lat/lon, optionally to a zoom and
   * precision. Null while the viewport is not ready.
   */
  planFlight(lat: number, lon: number, targetZoom: number | null,
    targetPrecision: number | null, durationMs: number = 550,
    glide: boolean = false): GlobeFlightPlan | null {
    if (this.baseRadiusPx <= 0) {
      return null;
    }
    const startLat: number = this.centerLat;
    const startLon: number = this.centerLon;
    const endLat: number = Math.min(GlobeCamera.MAX_LAT,
      Math.max(GlobeCamera.MIN_LAT, lat));
    const endLon: number = GlobeMath.normalizeLon(lon);
    const startZoom: number = this.zoom;
    const endZoom: number = Math.min(GlobeMath.MAX_ZOOM,
      Math.max(GlobeMath.MIN_ZOOM, targetZoom !== null ? targetZoom : this.zoom));
    const zoomRatio: number = endZoom / startZoom;
    const zoomFloor: number = Math.min(GlobeMath.MIN_ZOOM, startZoom);
    let flight: GlobeFlight | null = null;
    if (!glide && (zoomRatio > GlobeCamera.FLIGHT_ZOOM_RATIO ||
      zoomRatio < 1 / GlobeCamera.FLIGHT_ZOOM_RATIO)) {
      flight = new GlobeFlight(
        GlobeFlight.arc(startLat, startLon, endLat, endLon),
        this.visibleWidth(startZoom),
        this.visibleWidth(endZoom));
    }
    let duration: number = durationMs;
    if (flight !== null) {
      duration = Math.min(GlobeCamera.MAX_FLIGHT_MS,
        Math.max(durationMs, Math.trunc(flight.pathLength * GlobeCamera.FLIGHT_MS_PER_UNIT)));
    }
    const dLon: number = GlobeMath.normalizeLon(endLon - startLon);
    return new GlobeFlightPlan(startLat, startLon, startZoom, endLat, endLon, endZoom,
      targetPrecision, duration, dLon, zoomFloor, flight,
      this.baseRadiusPx, this.screenMinPx);
  }

  /** Applies one animation frame from a flight plan. */
  applyFlightSample(sample: GlobeCameraSample): void {
    this.centerLat = Math.min(GlobeCamera.MAX_LAT,
      Math.max(GlobeCamera.MIN_LAT, sample.lat));
    this.centerLon = sample.lon;
    this.zoom = sample.zoom;
    this.syncPrecisionFromZoom();
    this.syncSelection();
  }

  /** Lands exactly on the plan target once the motion completes. */
  finishFlight(plan: GlobeFlightPlan): void {
    this.centerLat = plan.endLat;
    this.centerLon = plan.endLon;
    this.zoom = plan.endZoom;
    const endPrecision: number | null = plan.endPrecision;
    if (endPrecision !== null) {
      this.precision = Math.min(GlobeMath.MAX_PRECISION, Math.max(1, endPrecision));
    } else {
      this.syncPrecisionFromZoom();
    }
    this.syncSelection();
  }

  /**
   * Button-driven precision change: the zoom that frames a cell of the new
   * precision. Null while the viewport is not ready.
   */
  targetZoomForPrecisionChange(newPrecision: number): number | null {
    const p: number = Math.min(GlobeMath.MAX_PRECISION, Math.max(1, newPrecision));
    if (p === this.precision || this.baseRadiusPx <= 0) {
      return null;
    }
    return GlobeMath.zoomForPrecision(p, this.baseRadiusPx, this.screenMinPx);
  }

  /** The - button: one level coarser, or the whole globe when already at level 1. */
  planZoomOut(): GlobeFlightPlan | null {
    if (!this.canZoomOut || this.baseRadiusPx <= 0) {
      return null;
    }
    if (this.precision > 1) {
      const targetZoom: number | null = this.targetZoomForPrecisionChange(this.precision - 1);
      if (targetZoom === null) {
        return null;
      }
      return this.planFlight(this.centerLat, this.centerLon, targetZoom, this.precision - 1, 450);
    }
    return this.planFlight(this.centerLat, this.centerLon, GlobeMath.MIN_ZOOM, 1, 450);
  }

  private syncSelection(): void {
    if (this.baseRadiusPx <= 0) {
      return;
    }
    this.selectedGeohash = Geohash.encode(this.centerLat, this.centerLon, this.precision);
  }
}
