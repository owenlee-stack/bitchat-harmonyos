/**
 * The 3D globe geohash picker page (T067, US13).
 *
 * HarmonyOS port of the Android GeohashPickerActivity: an orthographic globe
 * rendered on a Canvas from the bundled Natural Earth rawfile geometry, with
 * drag rotation, pinch zoom, tap/double-tap flights along van Wijk curves,
 * the geohash grid selection, an in-memory bookmark row and a join action
 * whose result is parked in GeohashPickerResult before routing back (the
 * location-channel surface in T068 consumes it). The render/gesture math
 * lives in the host-runnable service/globe kernel; this page owns only the
 * frame loop, the input plumbing and the chrome.
 */
import { router } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { Geohash, GeohashBounds, GeohashLevels, GeohashPoint } from '../service/nostr/GeohashService';
import { GlobeCamera, GlobeFlightPlan } from '../service/globe/GlobeCamera';
import { GlobeLatLng, GlobeMath, GlobePreparedProjector, GlobeProjection } from '../service/globe/GlobeMath';
import { GlobeClipRect, GlobeDiscPoint, GlobeGeometry, GlobeSegment, GlobeXY } from '../service/globe/GlobeGeometry';
import { GlobeCity, GlobeRing, GlobeWorldData } from '../service/globe/GlobeWorldData';
import { GeohashPickerResult } from '../service/globe/GeohashPickerResult';
import { GeohashBookmarksStore } from '../data/GeohashBookmarksStore';
import { ChatViewModel } from '../viewmodel/ChatViewModel';

const PAGE_BG = '#111111';
const SURFACE = '#1D1D1D';
const SURFACE_BORDER = '#3A3A3A';
const TEXT_PRIMARY = '#FFFFFF';
const TEXT_SECONDARY = '#9E9E9E';
const TEXT_TERTIARY = '#777777';
const ACCENT = '#32D74B';
const ACCENT_TEXT = '#04230C';
const GLOBE_LAND = '#16241B';
const GLOBE_OCEAN_CENTER = '#0A1410';
const GLOBE_OCEAN_EDGE = '#020604';
const GLOBE_BORDER = '#8A8A8A';
const GLOBE_GRID = '#9E9E9E';
const GLOBE_LABEL = '#9E9E9E';

const VIEWPORT_RADIUS_FRACTION = 0.44;
const TICKER_INTERVAL_MS = 16;
const GESTURE_HINT_TIMEOUT_MS = 12000;
const INTRO_DURATION_MS = 900;
const TAP_FLIGHT_MS = 450;
const DOUBLE_TAP_FLIGHT_MS = 500;
const DOUBLE_TAP_WINDOW_MS = 350;
const DOUBLE_TAP_ZOOM_STEP = 1.9;
const ZOOM_STEP_FLIGHT_MS = 650;
const WHOLE_GLOBE_FLIGHT_MS = 700;
const FOCUS_FLIGHT_MS = 650;
const CONTROL_SIZE = 44;
const CARD_RADIUS = 24;
const CHROME_RADIUS = 22;

class GlobeStar {
  readonly x: number;
  readonly y: number;
  readonly radiusVp: number;
  readonly alpha: number;

  constructor(x: number, y: number, radiusVp: number, alpha: number) {
    this.x = x;
    this.y = y;
    this.radiusVp = radiusVp;
    this.alpha = alpha;
  }
}

function buildGlobeStars(count: number): GlobeStar[] {
  const stars: GlobeStar[] = [];
  let seed: number = 42;
  const modulus: number = 2147483647;
  for (let i: number = 0; i < count; i++) {
    seed = (seed * 48271) % modulus;
    const x: number = seed / modulus;
    seed = (seed * 48271) % modulus;
    const y: number = seed / modulus;
    seed = (seed * 48271) % modulus;
    const radiusVp: number = 0.6 + (seed / modulus) * 1.5;
    seed = (seed * 48271) % modulus;
    const alpha: number = 0.15 + (seed / modulus) * 0.55;
    stars.push(new GlobeStar(x, y, radiusVp, alpha));
  }
  return stars;
}

function rgba(hex: string, alpha: number): string {
  const r: number = parseInt(hex.substring(1, 3), 16);
  const g: number = parseInt(hex.substring(3, 5), 16);
  const b: number = parseInt(hex.substring(5, 7), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

function coverageString(precision: number): string {
  let maxMeters: number;
  if (precision <= 1) {
    maxMeters = 5000000;
  } else if (precision === 2) {
    maxMeters = 1250000;
  } else if (precision === 3) {
    maxMeters = 156000;
  } else if (precision === 4) {
    maxMeters = 39100;
  } else if (precision === 5) {
    maxMeters = 4890;
  } else if (precision === 6) {
    maxMeters = 1220;
  } else if (precision === 7) {
    maxMeters = 153;
  } else if (precision === 8) {
    maxMeters = 38.2;
  } else if (precision === 9) {
    maxMeters = 4.77;
  } else if (precision === 10) {
    maxMeters = 1.19;
  } else {
    maxMeters = 1.19 * Math.pow(0.25, precision - 10);
  }
  const km: number = maxMeters / 1000;
  if (km >= 100) {
    return `~${Math.round(km)} km`;
  }
  if (km >= 1) {
    return `~${km.toFixed(1)} km`;
  }
  return `~${Math.round(maxMeters)} m`;
}

@Entry
@ComponentV2
struct GeohashPickerPage {
  private renderSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.renderSettings);
  private camera: GlobeCamera = new GlobeCamera();
  private stars: GlobeStar[] = buildGlobeStars(160);
  private land: GlobeRing[] = [];
  private borders: GlobeRing[] = [];
  private cities: GlobeCity[] = [];
  private landScratch: Float32Array = new Float32Array(3);
  private borderScratch: Float32Array = new Float32Array(3);
  private loaded: boolean = false;
  private pxPerVp: number = 1;
  private viewW: number = 0;
  private viewH: number = 0;
  private dirty: boolean = false;
  private activePlan: GlobeFlightPlan | null = null;
  private planStartMs: number = 0;
  private tickerId: number = -1;
  private hintTimeoutId: number = -1;
  private panning: boolean = false;
  private pinchActive: boolean = false;
  private lastPinchScale: number = 1;
  private panLastX: number = 0;
  private panLastY: number = 0;
  private lastTapMs: number = 0;
  private lastTapX: number = 0;
  private lastTapY: number = 0;
  private targetLat: number = 20;
  private targetLon: number = 10;
  private introPlayed: boolean = false;
  @Local private precisionLabel: number = 1;
  @Local private selectedGeohash: string = '';
  @Local private canZoomOut: boolean = false;
  @Local private hasInteracted: boolean = false;
  @Local private bookmarks: string[] = [];

  aboutToAppear(): void {
    this.pxPerVp = this.getUIContext().vp2px(1);
    this.readInitialTarget();
    this.camera.initialize(this.targetLat, this.targetLon, 1, true);
    this.loadWorld();
    this.loadBookmarks();
    this.tickerId = setInterval(() => {
      this.tick();
    }, TICKER_INTERVAL_MS);
    this.hintTimeoutId = setTimeout(() => {
      this.hasInteracted = true;
    }, GESTURE_HINT_TIMEOUT_MS);
  }

  aboutToDisappear(): void {
    if (this.tickerId >= 0) {
      clearInterval(this.tickerId);
      this.tickerId = -1;
    }
    if (this.hintTimeoutId >= 0) {
      clearTimeout(this.hintTimeoutId);
      this.hintTimeoutId = -1;
    }
  }

  private readInitialTarget(): void {
    const rawParams: Object | undefined = router.getParams();
    if (rawParams === undefined) {
      return;
    }
    try {
      const record: Record<string, Object> =
        JSON.parse(JSON.stringify(rawParams)) as Record<string, Object>;
      const initial: Object | undefined = record['initialGeohash'];
      if (typeof initial === 'string' && initial.length > 0) {
        const center: GeohashPoint = Geohash.decodeToCenter(initial.toLowerCase());
        this.targetLat = center.lat;
        this.targetLon = center.lon;
      }
    } catch (e) {
      // An invalid initial geohash falls back to the default target.
    }
  }

  private async loadWorld(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    try {
      const landBytes: Uint8Array = await context.resourceManager.getRawFileContent('world_land.geojson');
      this.land = GlobeWorldData.parseLand(decoder.decodeToString(landBytes));
      const borderBytes: Uint8Array = await context.resourceManager.getRawFileContent('world_borders.geojson');
      this.borders = GlobeWorldData.parseBorders(decoder.decodeToString(borderBytes));
      const cityBytes: Uint8Array = await context.resourceManager.getRawFileContent('world_cities.geojson');
      this.cities = GlobeWorldData.parseCities(decoder.decodeToString(cityBytes));
    } catch (e) {
      return;
    }
    let maxRingPoints: number = 1;
    for (let i: number = 0; i < this.land.length; i++) {
      maxRingPoints = Math.max(maxRingPoints, this.land[i].size);
    }
    this.landScratch = new Float32Array(maxRingPoints * 3);
    let maxBorderPoints: number = 1;
    for (let i: number = 0; i < this.borders.length; i++) {
      maxBorderPoints = Math.max(maxBorderPoints, this.borders[i].size);
    }
    this.borderScratch = new Float32Array(maxBorderPoints * 3);
    this.loaded = this.land.length > 0;
    this.dirty = true;
    this.playIntroIfReady();
  }

  private playIntroIfReady(): void {
    if (this.introPlayed || !this.loaded || this.camera.baseRadiusPx <= 0) {
      return;
    }
    this.introPlayed = true;
    this.startFlight(this.camera.planFlight(this.targetLat, this.targetLon,
      this.camera.introEndZoom(), 1, INTRO_DURATION_MS));
  }

  private applyViewport(newArea: Area): void {
    const wVp: number = Number(newArea.width);
    const hVp: number = Number(newArea.height);
    if (!(wVp > 0) || !(hVp > 0)) {
      return;
    }
    this.viewW = wVp * this.pxPerVp;
    this.viewH = hVp * this.pxPerVp;
    const minPx: number = Math.min(this.viewW, this.viewH);
    this.camera.setViewport(minPx * VIEWPORT_RADIUS_FRACTION, minPx);
    this.syncChrome();
    this.dirty = true;
    this.playIntroIfReady();
  }

  private syncChrome(): void {
    this.precisionLabel = this.camera.precision;
    this.selectedGeohash = this.camera.selectedGeohash;
    this.canZoomOut = this.camera.canZoomOut;
  }

  private startFlight(plan: GlobeFlightPlan | null): void {
    if (plan === null) {
      return;
    }
    this.activePlan = plan;
    this.planStartMs = Date.now();
    this.syncChrome();
  }

  private tick(): void {
    const plan: GlobeFlightPlan | null = this.activePlan;
    if (plan !== null) {
      const raw: number = Math.min(1, (Date.now() - this.planStartMs) / plan.durationMs);
      const eased: number = 1 - Math.pow(1 - raw, 3);
      this.camera.applyFlightSample(plan.sample(eased));
      if (raw >= 1) {
        this.camera.finishFlight(plan);
        this.activePlan = null;
      }
      this.syncChrome();
      this.drawFrame();
      return;
    }
    if (this.dirty) {
      this.dirty = false;
      this.drawFrame();
    }
  }

  private onPanStart(): void {
    this.panning = true;
    this.hasInteracted = true;
    this.activePlan = null;
    this.panLastX = 0;
    this.panLastY = 0;
  }

  private onPanUpdate(event: PanGestureEvent): void {
    const dxPx: number = (event.offsetX - this.panLastX) * this.pxPerVp;
    const dyPx: number = (event.offsetY - this.panLastY) * this.pxPerVp;
    this.panLastX = event.offsetX;
    this.panLastY = event.offsetY;
    this.camera.rotateBy(dxPx, dyPx);
    this.syncChrome();
    this.dirty = true;
  }

  private onPanEnd(): void {
    this.panning = false;
    this.dirty = true;
  }

  private onPinchStart(): void {
    this.pinchActive = true;
    this.hasInteracted = true;
    this.activePlan = null;
    this.lastPinchScale = 1;
  }

  private onPinchUpdate(event: GestureEvent): void {
    const scale: number = event.scale;
    if (!(scale > 0)) {
      return;
    }
    this.camera.zoomBy(scale / this.lastPinchScale);
    this.lastPinchScale = scale;
    this.syncChrome();
    this.dirty = true;
  }

  private onPinchEnd(): void {
    this.pinchActive = false;
    this.lastPinchScale = 1;
    this.dirty = true;
  }

  private onCanvasClick(event: ClickEvent): void {
    this.hasInteracted = true;
    const now: number = Date.now();
    const x: number = event.x * this.pxPerVp;
    const y: number = event.y * this.pxPerVp;
    const r: number = this.camera.globeRadiusPx;
    if (r <= 0) {
      return;
    }
    const isDouble: boolean = now - this.lastTapMs < DOUBLE_TAP_WINDOW_MS &&
      Math.abs(x - this.lastTapX) < this.pxPerVp * 24 &&
      Math.abs(y - this.lastTapY) < this.pxPerVp * 24;
    this.lastTapMs = now;
    this.lastTapX = x;
    this.lastTapY = y;
    const location: GlobeLatLng | null = GlobeMath.unproject(
      (x - this.viewW / 2) / r, (y - this.viewH / 2) / r,
      this.camera.centerLat, this.camera.centerLon);
    if (location === null) {
      return;
    }
    if (isDouble) {
      const targetZoom: number = Math.min(GlobeMath.MAX_ZOOM, this.camera.zoom * DOUBLE_TAP_ZOOM_STEP);
      this.startFlight(this.camera.planFlight(location.lat, location.lon, targetZoom, null,
        DOUBLE_TAP_FLIGHT_MS));
    } else {
      this.startFlight(this.camera.planFlight(location.lat, location.lon, null, null, TAP_FLIGHT_MS));
    }
  }

  private join(): void {
    const geohash: string = this.camera.selectedGeohash;
    if (geohash === '') {
      return;
    }
    GeohashPickerResult.setJoinedGeohash(geohash);
    router.back();
  }

  private focusChannel(geohash: string): void {
    try {
      const center: GeohashPoint = Geohash.decodeToCenter(geohash);
      const zoom: number = GlobeMath.zoomForPrecision(geohash.length,
        this.camera.baseRadiusPx, this.camera.screenMinPx);
      this.startFlight(this.camera.planFlight(center.lat, center.lon, zoom, geohash.length,
        FOCUS_FLIGHT_MS));
    } catch (e) {
      // An unparsable bookmark does nothing.
    }
  }

  private zoomIn(): void {
    const newPrecision: number = this.camera.precision + 1;
    const targetZoom: number | null = this.camera.targetZoomForPrecisionChange(newPrecision);
    if (targetZoom === null) {
      return;
    }
    this.startFlight(this.camera.planFlight(this.camera.centerLat, this.camera.centerLon,
      targetZoom, newPrecision, ZOOM_STEP_FLIGHT_MS));
  }

  private zoomOut(): void {
    this.startFlight(this.camera.planZoomOut());
  }

  private showWholeGlobe(): void {
    this.startFlight(this.camera.planFlight(this.camera.centerLat, this.camera.centerLon,
      GlobeMath.MIN_ZOOM, 1, WHOLE_GLOBE_FLIGHT_MS));
  }

  private addBookmark(): void {
    const geohash: string = this.camera.selectedGeohash;
    if (geohash === '' || this.bookmarks.indexOf(geohash) >= 0) {
      return;
    }
    // Persisted bookmarks (US13, T068): the store keeps them across
    // launches; the view model mirror refresh keeps the sheet in sync.
    GeohashBookmarksStore.getInstance().add(geohash)
      .then((): void => {
        this.bookmarks = GeohashBookmarksStore.getInstance().getList();
        ChatViewModel.getInstance().loadGeohashBookmarks();
      })
      .catch((): void => {
        // A failed write keeps the in-memory list untouched.
      });
  }

  /** Mirror the persisted bookmarks into the row (US13, T068). */
  private async loadBookmarks(): Promise<void> {
    try {
      const list: string[] = await GeohashBookmarksStore.getInstance().ensureLoaded();
      this.bookmarks = list;
    } catch (e) {
      this.bookmarks = [];
    }
  }

  private levelLabel(): string {
    return GeohashLevels.displayName(GeohashLevels.levelForLength(this.precisionLabel)).toLowerCase();
  }

  private coverageLabel(): string {
    return coverageString(this.precisionLabel);
  }

  private drawFrame(): void {
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    const w: number = this.viewW;
    const h: number = this.viewH;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = PAGE_BG;
    ctx.fillRect(0, 0, w, h);
    if (!this.loaded) {
      return;
    }
    const cx: number = w / 2;
    const cy: number = h / 2;
    const r: number = this.camera.globeRadiusPx;
    if (r <= 0) {
      return;
    }
    const cLat: number = this.camera.centerLat;
    const cLon: number = this.camera.centerLon;
    const moving: boolean = this.activePlan !== null || this.panning || this.pinchActive;
    const projector: GlobePreparedProjector = new GlobePreparedProjector(cLat, cLon);
    const clip: GlobeClipRect = new GlobeClipRect(-w, -h, w * 2, h * 2);
    this.drawStars(w, h);
    this.drawAtmosphere(cx, cy, r);
    this.drawOcean(cx, cy, r);
    this.drawGraticule(cx, cy, r, cLat, cLon, moving ? 10 : 4, clip);
    this.drawLand(projector, cx, cy, r, cLat, cLon, moving, clip);
    if (!moving) {
      this.drawBorders(projector, cx, cy, r, clip);
    }
    this.drawShading(cx, cy, r);
    this.drawCities(projector, cx, cy, r, w, h, moving);
    if (this.camera.selectedGeohash !== '') {
      this.drawGeohashGrid(cx, cy, r, cLat, cLon, clip);
      this.drawGeohashLabels(cx, cy, r, cLat, cLon);
    }
    this.drawCrosshair(cx, cy, moving);
  }

  private drawStars(w: number, h: number): void {
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    ctx.fillStyle = TEXT_PRIMARY;
    for (let i: number = 0; i < this.stars.length; i++) {
      const star: GlobeStar = this.stars[i];
      ctx.globalAlpha = star.alpha;
      ctx.beginPath();
      ctx.arc(star.x * w, star.y * h, star.radiusVp * this.pxPerVp, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  private drawAtmosphere(cx: number, cy: number, r: number): void {
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    const glowR: number = r * 1.22;
    const grad = ctx.createRadialGradient(cx, cy, 0, cx, cy, glowR);
    grad.addColorStop(0, rgba(ACCENT, 0.30));
    grad.addColorStop(0.75, rgba(ACCENT, 0.12));
    grad.addColorStop(1, rgba(ACCENT, 0));
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.arc(cx, cy, glowR, 0, Math.PI * 2);
    ctx.fill();
  }

  private drawOcean(cx: number, cy: number, r: number): void {
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    const gx: number = cx - r * 0.32;
    const gy: number = cy - r * 0.38;
    const grad = ctx.createRadialGradient(gx, gy, 0, gx, gy, r * 1.5);
    grad.addColorStop(0, GLOBE_OCEAN_CENTER);
    grad.addColorStop(0.7, GLOBE_OCEAN_CENTER);
    grad.addColorStop(1, GLOBE_OCEAN_EDGE);
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.fill();
  }

  private drawGraticule(cx: number, cy: number, r: number, cLat: number, cLon: number,
    step: number, clip: GlobeClipRect): void {
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    ctx.strokeStyle = rgba(TEXT_PRIMARY, 0.055);
    ctx.lineWidth = 1;
    ctx.beginPath();
    let lat: number = -75;
    while (lat <= 75) {
      let prev: GlobeProjection | null = null;
      let lon: number = -180;
      while (lon <= 180) {
        const p: GlobeProjection | null = GlobeMath.project(lat, lon, cLat, cLon);
        if (p !== null && p.cosC > 0.02) {
          if (prev !== null) {
            this.addGraticuleSegment(cx, cy, r, prev, p, clip);
          }
          prev = p;
        } else {
          prev = null;
        }
        lon += step;
      }
      lat += 15;
    }
    let lon2: number = -180;
    while (lon2 < 180) {
      let prev: GlobeProjection | null = null;
      let la: number = -90;
      while (la <= 90) {
        const p: GlobeProjection | null = GlobeMath.project(la, lon2, cLat, cLon);
        if (p !== null && p.cosC > 0.02) {
          if (prev !== null) {
            this.addGraticuleSegment(cx, cy, r, prev, p, clip);
          }
          prev = p;
        } else {
          prev = null;
        }
        la += step;
      }
      lon2 += 15;
    }
    ctx.stroke();
  }

  private addGraticuleSegment(cx: number, cy: number, r: number, from: GlobeProjection,
    to: GlobeProjection, clip: GlobeClipRect): void {
    const seg: GlobeSegment | null = GlobeGeometry.clipSegment(
      cx + from.x * r, cy + from.y * r, cx + to.x * r, cy + to.y * r, clip);
    if (seg === null) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    ctx.moveTo(seg.x0, seg.y0);
    ctx.lineTo(seg.x1, seg.y1);
  }

  private drawLand(projector: GlobePreparedProjector, cx: number, cy: number, r: number,
    cLat: number, cLon: number, moving: boolean, clip: GlobeClipRect): void {
    const stride: number = moving ? 2 : 1;
    const coastlineRuns: GlobeXY[][][] = [];
    for (let ringIndex: number = 0; ringIndex < this.land.length; ringIndex++) {
      const ring: GlobeRing = this.land[ringIndex];
      const ringStride: number = ring.size >= 64 ? stride : 1;
      const n: number = Math.trunc((ring.size - 1) / ringStride) + 1;
      if (n < 3 || n * 3 > this.landScratch.length) {
        continue;
      }
      const scratch: Float32Array = this.landScratch;
      let anyFront: boolean = false;
      let anyBack: boolean = false;
      for (let i: number = 0; i < n; i++) {
        const sourceIndex: number = Math.min(ring.size - 1, i * ringStride);
        projector.project(ring.projectionTerms, sourceIndex * 4, scratch, i * 3);
        if (scratch[i * 3 + 2] >= 0) {
          anyFront = true;
        } else {
          anyBack = true;
        }
      }
      if (!anyFront) {
        continue;
      }
      const pts: GlobeDiscPoint[] = [];
      for (let i: number = 0; i < n; i++) {
        pts.push(new GlobeDiscPoint(scratch[i * 3], scratch[i * 3 + 1], scratch[i * 3 + 2] > 0.005));
      }
      const runs: GlobeXY[][] = GlobeGeometry.buildFrontRuns(pts, true);
      const polygon: GlobeXY[] = GlobeGeometry.buildFillPolygon(pts, cx, cy, r);
      const invert: boolean = anyBack && GlobeGeometry.projectedFillNeedsInversion(
        polygon, ring.coords, ring.size, cx, cy, r, cLat, cLon);
      this.fillPolygonClipped(polygon, invert, GLOBE_LAND, 1, cx, cy, r, clip);
      coastlineRuns.push(runs);
    }
    for (let i: number = 0; i < coastlineRuns.length; i++) {
      this.strokeRuns(coastlineRuns[i], cx, cy, r, rgba(ACCENT, 0.45), 1.4, clip);
    }
  }

  private drawBorders(projector: GlobePreparedProjector, cx: number, cy: number, r: number,
    clip: GlobeClipRect): void {
    for (let lineIndex: number = 0; lineIndex < this.borders.length; lineIndex++) {
      const line: GlobeRing = this.borders[lineIndex];
      const n: number = line.size;
      if (n < 2 || n * 3 > this.borderScratch.length) {
        continue;
      }
      const scratch: Float32Array = this.borderScratch;
      let anyFront: boolean = false;
      for (let i: number = 0; i < n; i++) {
        projector.project(line.projectionTerms, i * 4, scratch, i * 3);
        if (scratch[i * 3 + 2] >= 0) {
          anyFront = true;
        }
      }
      if (!anyFront) {
        continue;
      }
      const pts: GlobeDiscPoint[] = [];
      for (let i: number = 0; i < n; i++) {
        pts.push(new GlobeDiscPoint(scratch[i * 3], scratch[i * 3 + 1], scratch[i * 3 + 2] > 0.005));
      }
      const runs: GlobeXY[][] = GlobeGeometry.buildFrontRuns(pts, false);
      this.strokeRuns(runs, cx, cy, r, rgba(GLOBE_BORDER, 0.5), 1.2, clip);
    }
  }

  private drawShading(cx: number, cy: number, r: number): void {
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    const gx: number = cx - r * 0.25;
    const gy: number = cy - r * 0.3;
    const grad = ctx.createRadialGradient(gx, gy, 0, gx, gy, r * 1.35);
    grad.addColorStop(0, 'rgba(0, 0, 0, 0)');
    grad.addColorStop(0.62, 'rgba(0, 0, 0, 0)');
    grad.addColorStop(0.88, 'rgba(0, 0, 0, 0.34)');
    grad.addColorStop(1, 'rgba(0, 0, 0, 0.72)');
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.arc(cx, cy, r + 1, 0, Math.PI * 2);
    ctx.fill();
    const linear = ctx.createLinearGradient(cx - r * 0.7, cy - r * 0.7, cx + r * 0.75, cy + r * 0.8);
    linear.addColorStop(0, 'rgba(0, 0, 0, 0)');
    linear.addColorStop(0.55, 'rgba(0, 0, 0, 0)');
    linear.addColorStop(1, 'rgba(0, 0, 0, 0.42)');
    ctx.fillStyle = linear;
    ctx.beginPath();
    ctx.arc(cx, cy, r + 1, 0, Math.PI * 2);
    ctx.fill();
  }

  private drawCities(projector: GlobePreparedProjector, cx: number, cy: number, r: number,
    w: number, h: number, moving: boolean): void {
    if (this.cities.length === 0) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    const zoom: number = this.camera.zoom;
    let maxRank: number = 1;
    if (zoom >= 40) {
      maxRank = 10;
    } else if (zoom >= 8) {
      maxRank = 4;
    } else if (zoom >= 2) {
      maxRank = 3;
    }
    const projection: Float32Array = new Float32Array(3);
    const fontPx: number = Math.round(10 * this.pxPerVp);
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    for (let i: number = 0; i < this.cities.length; i++) {
      const city: GlobeCity = this.cities[i];
      if (city.rank > maxRank) {
        continue;
      }
      projector.project(city.projectionTerms, 0, projection, 0);
      const cosC: number = projection[2];
      if (cosC < 0.03) {
        continue;
      }
      const sx: number = cx + projection[0] * r;
      const sy: number = cy + projection[1] * r;
      if (sx < -50 || sx > w + 50 || sy < -50 || sy > h + 50) {
        continue;
      }
      const alpha: number = Math.min(1, Math.max(0.25, cosC));
      const important: boolean = city.capital || city.megacity;
      const dotR: number = (important ? 2.6 : 1.8) * this.pxPerVp;
      ctx.globalAlpha = alpha;
      ctx.fillStyle = city.capital ? ACCENT : GLOBE_LABEL;
      ctx.beginPath();
      ctx.arc(sx, sy, dotR, 0, Math.PI * 2);
      ctx.fill();
      if (!moving && (zoom >= 6 || (important && zoom >= 2.5))) {
        const tx: number = sx + dotR + 3 * this.pxPerVp;
        ctx.font = `${fontPx}px sans-serif`;
        ctx.strokeStyle = rgba(PAGE_BG, 0.8 * alpha);
        ctx.lineWidth = fontPx * 0.16;
        ctx.strokeText(city.name, tx, sy);
        ctx.fillStyle = rgba(GLOBE_LABEL, 0.78 * alpha);
        ctx.fillText(city.name, tx, sy);
      }
    }
    ctx.globalAlpha = 1;
  }

  private drawGeohashGrid(cx: number, cy: number, r: number, cLat: number, cLon: number,
    clip: GlobeClipRect): void {
    const selected: string = this.camera.selectedGeohash;
    const cells: string[] = [selected];
    const neighbors: string[] = Geohash.neighborsSamePrecision(selected);
    for (let i: number = 0; i < neighbors.length; i++) {
      cells.push(neighbors[i]);
    }
    for (let cellIndex: number = 0; cellIndex < cells.length; cellIndex++) {
      const cell: string = cells[cellIndex];
      const isSelected: boolean = cell === selected;
      const b: GeohashBounds = Geohash.decodeToBounds(cell);
      const spanLat: number = b.latMax - b.latMin;
      const spanLon: number = b.lonMax - b.lonMin;
      const steps: number = Math.min(48, Math.max(4, Math.ceil(spanLat / 1.5)));
      const pts: GlobeDiscPoint[] = [];
      let s: number;
      let t: number;
      for (s = 0; s <= steps; s++) {
        t = s / steps;
        this.addCellPoint(pts, b.latMax, b.lonMin + spanLon * t, cLat, cLon);
      }
      for (s = 1; s <= steps; s++) {
        t = s / steps;
        this.addCellPoint(pts, b.latMax - spanLat * t, b.lonMax, cLat, cLon);
      }
      for (s = 1; s <= steps; s++) {
        t = s / steps;
        this.addCellPoint(pts, b.latMin, b.lonMax - spanLon * t, cLat, cLon);
      }
      for (s = 1; s < steps; s++) {
        t = s / steps;
        this.addCellPoint(pts, b.latMin + spanLat * t, b.lonMin, cLat, cLon);
      }
      let anyFront: boolean = false;
      for (let i: number = 0; i < pts.length; i++) {
        if (pts[i].front) {
          anyFront = true;
          break;
        }
      }
      if (!anyFront) {
        continue;
      }
      const runs: GlobeXY[][] = GlobeGeometry.buildFrontRuns(pts, true);
      if (isSelected) {
        this.fillPolygonClipped(GlobeGeometry.buildFillPolygon(pts, cx, cy, r), false,
          rgba(ACCENT, 0.20), 1, cx, cy, r, clip);
        this.strokeRuns(runs, cx, cy, r, rgba(ACCENT, 0.35), 7, clip);
        this.strokeRuns(runs, cx, cy, r, ACCENT, 3.2, clip);
      } else {
        this.fillPolygonClipped(GlobeGeometry.buildFillPolygon(pts, cx, cy, r), false,
          rgba(GLOBE_GRID, 0.05), 1, cx, cy, r, clip);
        this.strokeRuns(runs, cx, cy, r, rgba(GLOBE_GRID, 0.6), 1.6, clip);
      }
    }
  }

  private addCellPoint(pts: GlobeDiscPoint[], lat: number, lonRaw: number,
    cLat: number, cLon: number): void {
    let lon: number = lonRaw;
    while (lon - cLon > 180) {
      lon -= 360;
    }
    while (lon - cLon < -180) {
      lon += 360;
    }
    const p: GlobeProjection = GlobeMath.projectRaw(lat, lon, cLat, cLon);
    pts.push(new GlobeDiscPoint(p.x, p.y, p.cosC >= 0.005));
  }

  private drawGeohashLabels(cx: number, cy: number, r: number, cLat: number, cLon: number): void {
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    const selected: string = this.camera.selectedGeohash;
    const cells: string[] = [selected];
    const neighbors: string[] = Geohash.neighborsSamePrecision(selected);
    for (let i: number = 0; i < neighbors.length; i++) {
      cells.push(neighbors[i]);
    }
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    for (let cellIndex: number = 0; cellIndex < cells.length; cellIndex++) {
      const cell: string = cells[cellIndex];
      const isSelected: boolean = cell === selected;
      const center: GeohashPoint = Geohash.decodeToCenter(cell);
      const p: GlobeProjection | null = GlobeMath.project(center.lat, center.lon, cLat, cLon);
      if (p === null || p.cosC < 0.08) {
        continue;
      }
      const sx: number = cx + p.x * r;
      const sy: number = cy + p.y * r;
      const fontPx: number = Math.round((isSelected ? 12.5 : 10) * this.pxPerVp);
      ctx.font = `${fontPx}px sans-serif`;
      ctx.strokeStyle = rgba(PAGE_BG, isSelected ? 0.78 : 0.47);
      ctx.lineWidth = fontPx * 0.18;
      ctx.strokeText(cell, sx, sy);
      ctx.fillStyle = isSelected ? ACCENT : rgba(GLOBE_LABEL, 0.63 * Math.max(0.4, p.cosC));
      ctx.fillText(cell, sx, sy);
    }
  }

  private drawCrosshair(cx: number, cy: number, moving: boolean): void {
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    const color: string = rgba(ACCENT, moving ? 0.9 : 0.7);
    const gap: number = 5 * this.pxPerVp;
    const len: number = 9 * this.pxPerVp;
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.6 * this.pxPerVp;
    ctx.beginPath();
    ctx.moveTo(cx - gap - len, cy);
    ctx.lineTo(cx - gap, cy);
    ctx.moveTo(cx + gap, cy);
    ctx.lineTo(cx + gap + len, cy);
    ctx.moveTo(cx, cy - gap - len);
    ctx.lineTo(cx, cy - gap);
    ctx.moveTo(cx, cy + gap);
    ctx.lineTo(cx, cy + gap + len);
    ctx.stroke();
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.arc(cx, cy, 1.8 * this.pxPerVp, 0, Math.PI * 2);
    ctx.fill();
  }

  private fillPolygonClipped(polygon: GlobeXY[], invert: boolean, color: string,
    alpha: number, cx: number, cy: number, r: number, clip: GlobeClipRect): void {
    if (polygon.length < 3) {
      return;
    }
    const clipped: GlobeXY[] = GlobeGeometry.clipPolygon(polygon, clip);
    if (clipped.length < 3) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    const path: Path2D = new Path2D();
    if (invert) {
      path.ellipse(cx, cy, r, r, 0, 0, Math.PI * 2);
    }
    path.moveTo(clipped[0].x, clipped[0].y);
    for (let k: number = 1; k < clipped.length; k++) {
      path.lineTo(clipped[k].x, clipped[k].y);
    }
    path.closePath();
    ctx.globalAlpha = alpha;
    ctx.fillStyle = color;
    if (invert) {
      ctx.fill(path, 'evenodd');
    } else {
      ctx.fill(path, 'nonzero');
    }
    ctx.globalAlpha = 1;
  }

  private strokeRuns(runs: GlobeXY[][], cx: number, cy: number, r: number,
    color: string, width: number, clip: GlobeClipRect): void {
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.beginPath();
    for (let i: number = 0; i < runs.length; i++) {
      const run: GlobeXY[] = runs[i];
      if (run.length < 2) {
        continue;
      }
      for (let k: number = 1; k < run.length; k++) {
        const seg: GlobeSegment | null = GlobeGeometry.clipSegment(
          cx + run[k - 1].x * r, cy + run[k - 1].y * r,
          cx + run[k].x * r, cy + run[k].y * r, clip);
        if (seg === null) {
          continue;
        }
        ctx.moveTo(seg.x0, seg.y0);
        ctx.lineTo(seg.x1, seg.y1);
      }
    }
    ctx.stroke();
  }

  build() {
    Stack() {
      Canvas(this.canvasCtx)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.dirty = true;
        })
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.applyViewport(newArea);
        })
        .onClick((event: ClickEvent) => {
          this.onCanvasClick(event);
        })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PanGesture({ fingers: 1, distance: 5 })
              .onActionStart(() => {
                this.onPanStart();
              })
              .onActionUpdate((event: PanGestureEvent) => {
                this.onPanUpdate(event);
              })
              .onActionEnd(() => {
                this.onPanEnd();
              }),
            PinchGesture()
              .onActionStart(() => {
                this.onPinchStart();
              })
              .onActionUpdate((event: GestureEvent) => {
                this.onPinchUpdate(event);
              })
              .onActionEnd(() => {
                this.onPinchEnd();
              })
          )
        )
      Column() {
        Row() {
          Button('←')
            .fontSize(18)
            .fontColor(TEXT_PRIMARY)
            .width(CONTROL_SIZE)
            .height(CONTROL_SIZE)
            .borderRadius(CHROME_RADIUS)
            .backgroundColor(SURFACE)
            .border({ width: 1, color: SURFACE_BORDER })
            .onClick(() => {
              router.back();
            })
          Blank()
          Row({ space: 10 }) {
            Circle({ width: 8, height: 8 })
              .fill(TEXT_TERTIARY)
            Text('离线')
              .fontSize(11)
              .fontColor(TEXT_SECONDARY)
          }
          .height(CONTROL_SIZE)
          .padding({ left: 14, right: 14 })
          .borderRadius(CHROME_RADIUS)
          .backgroundColor(SURFACE)
          .border({ width: 1, color: SURFACE_BORDER })
          .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
        .hitTestBehavior(HitTestMode.None)

        Blank()
          .hitTestBehavior(HitTestMode.None)

        Row() {
          Blank()
            .hitTestBehavior(HitTestMode.None)
          Column({ space: 10 }) {
            Button('全球')
              .fontSize(11)
              .fontColor(TEXT_PRIMARY)
              .width(CONTROL_SIZE)
              .height(CONTROL_SIZE)
              .borderRadius(CHROME_RADIUS)
              .backgroundColor(SURFACE)
              .border({ width: 1, color: SURFACE_BORDER })
              .onClick(() => {
                this.showWholeGlobe();
              })
            Column() {
              Button('+')
                .fontSize(20)
                .fontColor(TEXT_PRIMARY)
                .width(CONTROL_SIZE)
                .height(CONTROL_SIZE)
                .borderRadius(CHROME_RADIUS)
                .backgroundColor(Color.Transparent)
                .onClick(() => {
                  this.zoomIn();
                })
              Divider()
                .width(20)
                .color(SURFACE_BORDER)
              Text(`${this.precisionLabel}`)
                .fontSize(13)
                .fontColor(ACCENT)
                .margin({ top: 4, bottom: 4 })
              Divider()
                .width(20)
                .color(SURFACE_BORDER)
              Button('−')
                .fontSize(20)
                .fontColor(this.canZoomOut ? TEXT_PRIMARY : TEXT_TERTIARY)
                .enabled(this.canZoomOut)
                .width(CONTROL_SIZE)
                .height(CONTROL_SIZE)
                .borderRadius(CHROME_RADIUS)
                .backgroundColor(Color.Transparent)
                .onClick(() => {
                  this.zoomOut();
                })
            }
            .borderRadius(CHROME_RADIUS)
            .backgroundColor(SURFACE)
            .border({ width: 1, color: SURFACE_BORDER })
          }
          .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .padding({ right: 12 })
        .hitTestBehavior(HitTestMode.None)

        Blank()
          .hitTestBehavior(HitTestMode.None)

        Column({ space: 12 }) {
          if (!this.hasInteracted) {
            Row({ space: 14 }) {
              Text('拖动旋转')
                .fontSize(11)
                .fontColor(TEXT_SECONDARY)
              Text('双指缩放')
                .fontSize(11)
                .fontColor(TEXT_SECONDARY)
              Text('点按选点')
                .fontSize(11)
                .fontColor(TEXT_SECONDARY)
            }
            .padding({ left: 14, right: 14, top: 9, bottom: 9 })
            .borderRadius(CHROME_RADIUS)
            .backgroundColor(SURFACE)
            .border({ width: 1, color: SURFACE_BORDER })
            .hitTestBehavior(HitTestMode.None)
          }
          Column({ space: 10 }) {
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text(this.selectedGeohash !== '' ? `#${this.selectedGeohash}` : '…')
                  .fontSize(20)
                  .fontColor(TEXT_PRIMARY)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${this.levelLabel()} · ${this.coverageLabel()}`)
                  .fontSize(12)
                  .fontColor(TEXT_SECONDARY)
                  .maxLines(1)
                Row({ space: 6 }) {
                  Circle({ width: 6, height: 6 })
                    .fill(TEXT_TERTIARY)
                  Text('暂无活动')
                    .fontSize(12)
                    .fontColor(TEXT_TERTIARY)
                }
                .hitTestBehavior(HitTestMode.None)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .hitTestBehavior(HitTestMode.None)
              Button('加入')
                .fontSize(15)
                .fontColor(ACCENT_TEXT)
                .enabled(this.selectedGeohash !== '')
                .height(CONTROL_SIZE)
                .borderRadius(CHROME_RADIUS)
                .padding({ left: 20, right: 20 })
                .backgroundColor(ACCENT)
                .onClick(() => {
                  this.join();
                })
            }
            .width('100%')
            .hitTestBehavior(HitTestMode.None)

            Row({ space: 8 }) {
              Button('收藏')
                .fontSize(12)
                .fontColor(TEXT_SECONDARY)
                .height(32)
                .borderRadius(16)
                .padding({ left: 12, right: 12 })
                .backgroundColor(PAGE_BG)
                .border({ width: 1, color: SURFACE_BORDER })
                .enabled(this.selectedGeohash !== '')
                .onClick(() => {
                  this.addBookmark();
                })
              if (this.bookmarks.length > 0) {
                Scroll() {
                  Row({ space: 8 }) {
                    ForEach(this.bookmarks, (geohash: string) => {
                      Text(`#${geohash}`)
                        .fontSize(12)
                        .fontColor(TEXT_SECONDARY)
                        .maxLines(1)
                        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                        .borderRadius(14)
                        .backgroundColor(PAGE_BG)
                        .border({ width: 1, color: SURFACE_BORDER })
                        .onClick(() => {
                          this.focusChannel(geohash);
                        })
                    }, (geohash: string) => geohash)
                  }
                }
                .scrollable(ScrollDirection.Horizontal)
                .layoutWeight(1)
                .height(32)
              }
            }
            .width('100%')
            .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .padding(16)
          .borderRadius(CARD_RADIUS)
          .backgroundColor(SURFACE)
          .border({ width: 1, color: SURFACE_BORDER })
          .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })
        .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAGE_BG)
  }
}
