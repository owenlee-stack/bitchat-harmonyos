/**
 * Contract vectors for the globe picker kernel (T067, spec US13), mirrored
 * from bitchat-android: GlobeMath.kt (orthographic projection golden
 * vectors, unproject round-trip, normalizeLon, cell spans, auto precision
 * thresholds), GlobeFlight.kt (van Wijk & Nuij zoom-only and panning
 * curves, great-circle arc/slerp), the GlobeView.kt geometry helpers
 * (front-run splitting with limb padding, horizon fill polygons, geographic
 * ring containment, screen polygon containment, Liang-Barsky segment and
 * Sutherland-Hodgman polygon clipping), LandData.kt (GeoJSON parsing for
 * land/borders/cities with (lon, lat) -> (lat, lon) reordering and
 * precomputed projection terms), GlobeState.kt (camera opening state,
 * drag rotation, pinch zoom with automatic precision, zoom-out gating,
 * flight-plan endpoints and glide interpolation) and the picker join
 * result handoff.
 */
import { ContractAssert } from './ContractAssert';
import { Geohash } from '../../main/ets/service/nostr/GeohashService';
import {
  GlobeCamera,
  GlobeCameraSample,
  GlobeFlightPlan
} from '../../main/ets/service/globe/GlobeCamera';
import { GlobeFlight, GlobeFlightSample } from '../../main/ets/service/globe/GlobeFlight';
import {
  GlobeClipRect,
  GlobeDiscPoint,
  GlobeGeometry,
  GlobeSegment,
  GlobeXY
} from '../../main/ets/service/globe/GlobeGeometry';
import {
  GlobeLatLng,
  GlobeMath,
  GlobePreparedProjector,
  GlobeProjection
} from '../../main/ets/service/globe/GlobeMath';
import { GeohashPickerResult } from '../../main/ets/service/globe/GeohashPickerResult';
import { GlobeCity, GlobeRing, GlobeWorldData } from '../../main/ets/service/globe/GlobeWorldData';

export function runGlobeKernelContractTests(t: ContractAssert): void {
  // ---- GlobeMath: orthographic projection golden vectors ----
  {
    const center: GlobeProjection = GlobeMath.projectRaw(10, 20, 10, 20);
    t.isTrue(Math.abs(center.x) < 1e-9, 'projection of the view center has x = 0');
    t.isTrue(Math.abs(center.y) < 1e-9, 'projection of the view center has y = 0');
    t.isTrue(Math.abs(center.cosC - 1) < 1e-9, 'projection of the view center has cosC = 1');

    const p: GlobeProjection = GlobeMath.projectRaw(10, 20, 0, 0);
    t.isTrue(Math.abs(p.x - Math.cos(GlobeMath.toRadians(10)) * Math.sin(GlobeMath.toRadians(20))) < 1e-9,
      'orthographic x = cos(lat) * sin(dLon)');
    t.isTrue(Math.abs(p.y + Math.sin(GlobeMath.toRadians(10))) < 1e-9,
      'orthographic y = -sin(lat) for an equatorial center');
    t.isTrue(Math.abs(p.cosC - (Math.cos(GlobeMath.toRadians(10)) * Math.cos(GlobeMath.toRadians(20)))) < 1e-9,
      'cosC = cos(lat) * cos(dLon) for an equatorial center');

    const behind: GlobeProjection | null = GlobeMath.project(-10, -160, 10, 20);
    t.isNull<GlobeProjection>(behind, 'a point on the far side projects to null');

    const raw: GlobeProjection = GlobeMath.projectRaw(35, 30, 20, 15);
    const roundTrip: GlobeLatLng | null = GlobeMath.unproject(raw.x, raw.y, 20, 15);
    t.isNotNull<GlobeLatLng>(roundTrip, 'unproject of a disc point returns a location');
    if (roundTrip !== null) {
      t.isTrue(Math.abs(roundTrip.lat - 35) < 1e-9, 'unproject round-trips latitude');
      t.isTrue(Math.abs(GlobeMath.normalizeLon(roundTrip.lon - 30)) < 1e-9,
        'unproject round-trips longitude');
    }

    const outside: GlobeLatLng | null = GlobeMath.unproject(2, 0, 20, 15);
    t.isNull<GlobeLatLng>(outside, 'unproject outside the disc returns null');

    const discCenter: GlobeLatLng | null = GlobeMath.unproject(0, 0, 12, 34);
    t.isNotNull<GlobeLatLng>(discCenter, 'unproject of the disc center returns the view center');
    if (discCenter !== null) {
      t.isTrue(Math.abs(discCenter.lat - 12) < 1e-9, 'unproject of the disc center keeps latitude');
      t.isTrue(Math.abs(discCenter.lon - 34) < 1e-9, 'unproject of the disc center keeps longitude');
    }
  }

  // ---- GlobeMath: longitude normalization ----
  {
    t.isTrue(Math.abs(GlobeMath.normalizeLon(190) + 170) < 1e-12, 'normalizeLon(190) = -170');
    t.isTrue(Math.abs(GlobeMath.normalizeLon(-190) - 170) < 1e-12, 'normalizeLon(-190) = 170');
    t.isTrue(Math.abs(GlobeMath.normalizeLon(370) - 10) < 1e-12, 'normalizeLon(370) = 10');
    t.isTrue(Math.abs(GlobeMath.normalizeLon(-370) + 10) < 1e-12, 'normalizeLon(-370) = -10');
    t.isTrue(Math.abs(GlobeMath.normalizeLon(180) - 180) < 1e-12, 'normalizeLon(180) stays 180');
  }

  // ---- GlobeMath: geohash cell spans and zoom-precision mapping ----
  {
    t.isTrue(Math.abs(GlobeMath.cellSpanLat(1) - 45) < 1e-12, 'precision-1 cell spans 45 degrees of latitude');
    t.isTrue(Math.abs(GlobeMath.cellSpanLon(1) - 45) < 1e-12, 'precision-1 cell spans 45 degrees of longitude');
    t.isTrue(Math.abs(GlobeMath.cellSpanLat(2) - 5.625) < 1e-12, 'precision-2 cell spans 5.625 degrees of latitude');
    t.isTrue(Math.abs(GlobeMath.cellSpanLon(2) - 11.25) < 1e-12, 'precision-2 cell spans 11.25 degrees of longitude');
    t.isTrue(Math.abs(GlobeMath.cellSpanLat(5) - 180 / 4096) < 1e-12, 'precision-5 latitude span is 180/2^12');
    t.isTrue(Math.abs(GlobeMath.cellSpanLon(5) - 360 / 8192) < 1e-12, 'precision-5 longitude span is 360/2^13');
    t.isTrue(Math.abs(GlobeMath.cellSpanLat(6) - 180 / 32768) < 1e-12, 'precision-6 latitude span is 180/2^15');
    t.isTrue(Math.abs(GlobeMath.cellSpanLon(6) - 360 / 32768) < 1e-12, 'precision-6 longitude span is 360/2^15');

    t.equalNumber(1, GlobeMath.autoPrecision(200, 800),
      'auto precision stays at 1 when a level-1 cell is already below the 22% share');
    t.equalNumber(2, GlobeMath.autoPrecision(2000, 800),
      'auto precision reaches 2 when level-2 cells span the 22% share');
    t.equalNumber(1, GlobeMath.autoPrecision(100, 400),
      'auto precision stays at 1 on a small globe');

    const threshold: number = GlobeMath.thresholdZoomForPrecision(2, 200, 800);
    t.isTrue(Math.abs(threshold - (800 * 0.22) / (GlobeMath.cellSpanLat(2) * Math.PI / 180 * 200)) < 1e-9,
      'threshold zoom for precision 2 matches the 22% cell share formula');

    const framing: number = GlobeMath.zoomForPrecision(2, 200, 800);
    const expectedFraming: number = ((800 / 3) / (GlobeMath.cellSpanLat(2) * Math.PI / 180)) / 200;
    t.isTrue(Math.abs(framing - expectedFraming) < 1e-9,
      'zoomForPrecision frames a cell at a third of the screen');
    t.isTrue(framing >= GlobeMath.MIN_ZOOM && framing <= GlobeMath.MAX_ZOOM,
      'zoomForPrecision stays within the zoom bounds');
  }

  // ---- GlobePreparedProjector matches projectRaw ----
  {
    const projector: GlobePreparedProjector = new GlobePreparedProjector(20, 15);
    const terms: Float32Array = new Float32Array(4);
    const out: Float32Array = new Float32Array(3);
    const lats: number[] = [10, 35, -45];
    const lons: number[] = [20, -120, 170];
    for (let i: number = 0; i < lats.length; i++) {
      terms[0] = Math.sin(GlobeMath.toRadians(lats[i]));
      terms[1] = Math.cos(GlobeMath.toRadians(lats[i]));
      terms[2] = Math.sin(GlobeMath.toRadians(lons[i]));
      terms[3] = Math.cos(GlobeMath.toRadians(lons[i]));
      projector.project(terms, 0, out, 0);
      const raw: GlobeProjection = GlobeMath.projectRaw(lats[i], lons[i], 20, 15);
      t.isTrue(Math.abs(out[0] - raw.x) < 1e-6, 'prepared projector x matches projectRaw');
      t.isTrue(Math.abs(out[1] - raw.y) < 1e-6, 'prepared projector y matches projectRaw');
      t.isTrue(Math.abs(out[2] - raw.cosC) < 1e-6, 'prepared projector cosC matches projectRaw');
    }
  }

  // ---- GlobeFlight: great-circle helpers ----
  {
    t.isTrue(Math.abs(GlobeFlight.arc(0, 0, 0, 90) - Math.PI / 2) < 1e-9,
      'arc between equator points 90 degrees apart is pi/2');
    t.isTrue(Math.abs(GlobeFlight.arc(0, 0, 0, 180) - Math.PI) < 1e-9,
      'arc between antipodes is pi');
    t.isTrue(GlobeFlight.arc(10, 20, 10, 20) < 1e-9, 'arc of a point with itself is zero');

    const mid: GlobeLatLng = GlobeFlight.slerp(0, 0, 0, 90, 0.5);
    t.isTrue(Math.abs(mid.lat) < 1e-9, 'slerp midpoint on the equator stays on the equator');
    t.isTrue(Math.abs(mid.lon - 45) < 1e-9, 'slerp midpoint of 0 and 90 degrees is 45 degrees');
    const same: GlobeLatLng = GlobeFlight.slerp(10, 20, 10, 20, 0.7);
    t.isTrue(Math.abs(same.lat - 10) < 1e-9 && Math.abs(same.lon - 20) < 1e-9,
      'slerp of a point with itself stays at the point');
  }

  // ---- GlobeFlight: zoom-only curve (distance below epsilon) ----
  {
    const flight: GlobeFlight = new GlobeFlight(0, 2, 0.5);
    t.isTrue(Math.abs(flight.pathLength - Math.abs(Math.log(0.5 / 2) / GlobeFlight.RHO)) < 1e-9,
      'zoom-only path length is |ln(w1/w0)/rho|');
    const start: GlobeFlightSample = flight.at(0);
    t.isTrue(Math.abs(start.width - 2) < 1e-9, 'zoom-only flight starts at the start width');
    const middle: GlobeFlightSample = flight.at(0.5);
    t.isTrue(Math.abs(middle.fraction - 0.5) < 1e-9, 'zoom-only fraction tracks progress');
    t.isTrue(Math.abs(middle.width - 1) < 1e-9,
      'zoom-only width halves at the midpoint of a 4x zoom');
    const end: GlobeFlightSample = flight.at(1);
    t.isTrue(Math.abs(end.fraction - 1) < 1e-12 && Math.abs(end.width - 0.5) < 1e-12,
      'zoom-only flight ends at (1, endWidth)');
  }

  // ---- GlobeFlight: panning curve (van Wijk & Nuij) ----
  {
    const flight: GlobeFlight = new GlobeFlight(1.0, 2, 0.5);
    t.isTrue(flight.pathLength > 0, 'panning flight has positive path length');
    const start: GlobeFlightSample = flight.at(0);
    t.isTrue(Math.abs(start.fraction) < 1e-6, 'panning flight starts at fraction 0');
    t.isTrue(Math.abs(start.width - 2) < 1e-6, 'panning flight starts at the start width');
    const end: GlobeFlightSample = flight.at(1);
    t.isTrue(Math.abs(end.fraction - 1) < 1e-12 && Math.abs(end.width - 0.5) < 1e-12,
      'panning flight ends at (1, endWidth)');
    const quarter: GlobeFlightSample = flight.at(0.25);
    const half: GlobeFlightSample = flight.at(0.5);
    const threeQuarters: GlobeFlightSample = flight.at(0.75);
    t.isTrue(quarter.fraction > 0 && half.fraction > quarter.fraction &&
      threeQuarters.fraction > half.fraction,
      'panning fraction increases monotonically');
    t.isTrue(half.width < quarter.width && threeQuarters.width < half.width,
      'panning width decreases monotonically while zooming in');
  }

  // ---- GlobeGeometry: geographic ring containment ----
  {
    const coords: Float32Array = new Float32Array([
      0, 0,
      0, 10,
      10, 10,
      10, 0
    ]);
    t.isTrue(GlobeGeometry.ringContainsLocation(coords, 4, 5, 5),
      'ring contains its interior point');
    t.isFalse(GlobeGeometry.ringContainsLocation(coords, 4, 15, 5),
      'ring does not contain a point north of it');
    t.isFalse(GlobeGeometry.ringContainsLocation(coords, 4, 5, 15),
      'ring does not contain a point east of it');
    t.isFalse(GlobeGeometry.ringContainsLocation(coords, 4, -5, 5),
      'ring does not contain a point south of it');
    t.isFalse(GlobeGeometry.ringContainsLocation(coords, 4, 5, -5),
      'ring does not contain a point west of it');
    t.isFalse(GlobeGeometry.ringContainsLocation(coords, 4, 5, 179),
      'a probe near the antimeridian does not see a ring at the prime meridian');
  }

  // ---- GlobeGeometry: screen-space polygon containment ----
  {
    const square: GlobeXY[] = [
      new GlobeXY(0, 0),
      new GlobeXY(10, 0),
      new GlobeXY(10, 10),
      new GlobeXY(0, 10)
    ];
    t.isTrue(GlobeGeometry.polygonContains(square, 5, 5), 'polygon contains its interior');
    t.isFalse(GlobeGeometry.polygonContains(square, 15, 5), 'polygon excludes outside points');
    t.isFalse(GlobeGeometry.polygonContains(square, -1, -1), 'polygon excludes the outside corner');
  }

  // ---- GlobeGeometry: front-run splitting ----
  {
    const allFront: GlobeDiscPoint[] = [];
    for (let i: number = 0; i < 8; i++) {
      const angle: number = i * Math.PI / 4;
      allFront.push(new GlobeDiscPoint(Math.cos(angle), Math.sin(angle), true));
    }
    const frontRuns: GlobeXY[][] = GlobeGeometry.buildFrontRuns(allFront, true);
    t.equalNumber(1, frontRuns.length, 'a fully front-facing ring yields one run');
    t.equalNumber(9, frontRuns[0].length, 'a closed fully front-facing run repeats its first point');
    t.isTrue(Math.abs(frontRuns[0][0].x - 1) < 1e-6 && Math.abs(frontRuns[0][0].y) < 1e-6,
      'the front run starts at the first point');
    t.isTrue(Math.abs(frontRuns[0][8].x - 1) < 1e-6 && Math.abs(frontRuns[0][8].y) < 1e-6,
      'the closed front run ends at its first point');

    // Far-side sphere points project inside the disc (their shadow), so the
    // back points here stay within the unit circle like real geometry.
    const mixed: GlobeDiscPoint[] = [
      new GlobeDiscPoint(0.5, 0, true),
      new GlobeDiscPoint(0.2, 0.3, false),
      new GlobeDiscPoint(-0.1, 0.4, false),
      new GlobeDiscPoint(0, 0.5, true)
    ];
    const runs: GlobeXY[][] = GlobeGeometry.buildFrontRuns(mixed, true);
    t.equalNumber(1, runs.length, 'the mixed ring closes into a single run across the seam');
    t.equalNumber(4, runs.length > 0 ? runs[0].length : 0,
      'the merged run carries the trailing front points plus the first run');
    t.isTrue(Math.abs(runs[0][0].x) < 1e-3 && Math.abs(runs[0][0].y - 0.5) < 1e-3,
      'the merged run opens at the trailing limb transition');
    t.isTrue(Math.abs(runs[0][2].x - 0.5) < 1e-6 && Math.abs(runs[0][2].y) < 1e-6,
      'the merged run carries the leading front point');
  }

  // ---- GlobeGeometry: horizon fill polygon ----
  {
    const mixed: GlobeDiscPoint[] = [
      new GlobeDiscPoint(0.5, 0, true),
      new GlobeDiscPoint(2, 0, false),
      new GlobeDiscPoint(0, 2, false),
      new GlobeDiscPoint(0, 0.5, true)
    ];
    const cx: number = 100;
    const cy: number = 100;
    const r: number = 50;
    const polygon: GlobeXY[] = GlobeGeometry.buildFillPolygon(mixed, cx, cy, r);
    t.isTrue(polygon.length > 5, 'the fill polygon inserts horizon arc steps');
    for (let i: number = 0; i < polygon.length; i++) {
      const dx: number = polygon[i].x - cx;
      const dy: number = polygon[i].y - cy;
      t.isTrue(Math.sqrt(dx * dx + dy * dy) <= r * 1.001,
        'fill polygon points stay within the globe radius');
    }
    let limbFound: boolean = false;
    for (let i: number = 0; i < polygon.length; i++) {
      if (Math.abs(polygon[i].x - (cx + r)) < 1e-6 && Math.abs(polygon[i].y - cy) < 1e-6) {
        limbFound = true;
      }
    }
    t.isTrue(limbFound, 'a back-facing point on the +x axis clamps onto the limb');
  }

  // ---- GlobeGeometry: fill inversion heuristic ----
  {
    const coords: Float32Array = new Float32Array([
      0, 0,
      0, 10,
      10, 10,
      10, 0
    ]);
    const front: GlobeDiscPoint[] = [
      new GlobeDiscPoint(0.2, 0.2, true),
      new GlobeDiscPoint(0.2, 0.8, true),
      new GlobeDiscPoint(0.8, 0.8, true),
      new GlobeDiscPoint(0.8, 0.2, true)
    ];
    const polygon: GlobeXY[] = GlobeGeometry.buildFillPolygon(front, 100, 100, 50);
    t.isFalse(GlobeGeometry.projectedFillNeedsInversion(polygon, coords, 4, 100, 100, 50, 5, 5),
      'a consistent projection does not need fill inversion');
  }

  // ---- GlobeGeometry: segment and polygon clipping ----
  {
    const rect: GlobeClipRect = new GlobeClipRect(0, 0, 10, 10);
    const inside: GlobeSegment | null = GlobeGeometry.clipSegment(2, 2, 8, 8, rect);
    t.isNotNull<GlobeSegment>(inside, 'an inside segment survives clipping');
    if (inside !== null) {
      t.isTrue(Math.abs(inside.x0 - 2) < 1e-9 && Math.abs(inside.x1 - 8) < 1e-9,
        'an inside segment keeps its endpoints');
    }
    const crossing: GlobeSegment | null = GlobeGeometry.clipSegment(-5, -5, 20, 20, rect);
    t.isNotNull<GlobeSegment>(crossing, 'a crossing segment survives clipping');
    if (crossing !== null) {
      t.isTrue(Math.abs(crossing.x0) < 1e-9 && Math.abs(crossing.y0) < 1e-9 &&
        Math.abs(crossing.x1 - 10) < 1e-9 && Math.abs(crossing.y1 - 10) < 1e-9,
        'a diagonal segment clips to the rect corners');
    }
    t.isNull<GlobeSegment>(GlobeGeometry.clipSegment(-5, 2, -1, 8, rect),
      'a fully outside segment clips to null');
    const partial: GlobeSegment | null = GlobeGeometry.clipSegment(-5, 5, 5, 5, rect);
    t.isNotNull<GlobeSegment>(partial, 'a half-outside segment survives clipping');
    if (partial !== null) {
      t.isTrue(Math.abs(partial.x0) < 1e-9 && Math.abs(partial.x1 - 5) < 1e-9,
        'a half-outside segment clips at the rect edge');
    }

    const big: GlobeXY[] = [
      new GlobeXY(0, 0),
      new GlobeXY(10, 0),
      new GlobeXY(10, 10),
      new GlobeXY(0, 10)
    ];
    const clipped: GlobeXY[] = GlobeGeometry.clipPolygon(big, new GlobeClipRect(2, 2, 8, 8));
    t.isTrue(clipped.length >= 3, 'a clipped polygon keeps at least a triangle');
    for (let i: number = 0; i < clipped.length; i++) {
      t.isTrue(clipped[i].x >= 2 - 1e-9 && clipped[i].x <= 8 + 1e-9 &&
        clipped[i].y >= 2 - 1e-9 && clipped[i].y <= 8 + 1e-9,
        'clipped polygon points stay inside the rect');
    }
  }

  // ---- GlobeWorldData: GeoJSON parsing ----
  {
    const landText: string = '{"geometries":[' +
      '{"type":"Polygon","coordinates":[[[0,0],[10,0],[10,10],[0,0]]]},' +
      '{"type":"MultiPolygon","coordinates":[[[[20,0],[30,0],[30,5],[20,0]]]]}]}';
    const land: GlobeRing[] = GlobeWorldData.parseLand(landText);
    t.equalNumber(2, land.length, 'Polygon and MultiPolygon geometries both produce rings');
    t.equalNumber(4, land[0].size, 'the first land ring keeps all its points');
    t.isTrue(Math.abs(land[0].coords[2]) < 1e-9 && Math.abs(land[0].coords[3] - 10) < 1e-9,
      'GeoJSON [lon, lat] pairs are stored as (lat, lon)');
    t.isTrue(Math.abs(land[0].coords[4] - 10) < 1e-9 && Math.abs(land[0].coords[5] - 10) < 1e-9,
      'the third point reorders to (lat, lon)');
    t.isTrue(Math.abs(land[0].projectionTerms[0] - Math.sin(GlobeMath.toRadians(0))) < 1e-9,
      'land rings precompute sin(latitude) projection terms');

    const bordersText: string = '{"geometries":[' +
      '{"type":"LineString","coordinates":[[0,0],[1,1],[2,2]]},' +
      '{"type":"MultiLineString","coordinates":[[[2,2],[3,3]],[[4,4],[5,5]]]}]}';
    const borders: GlobeRing[] = GlobeWorldData.parseBorders(bordersText);
    t.equalNumber(3, borders.length, 'LineString and MultiLineString parts all produce rings');
    t.equalNumber(3, borders[0].size, 'the first border line keeps its vertex count');
    t.equalNumber(2, borders[2].size, 'the last MultiLineString part keeps its vertex count');

    const citiesText: string = '{"cities":[' +
      '{"n":"Testville","lat":1.5,"lon":2.5,"r":3,"cap":1},' +
      '{"n":"Plainview","lat":-1.25,"lon":-2.5,"r":1}]}';
    const cities: GlobeCity[] = GlobeWorldData.parseCities(citiesText);
    t.equalNumber(2, cities.length, 'all city entries parse');
    t.equalString('Testville', cities[0].name, 'city names parse');
    t.isTrue(cities[0].capital, 'cap flag 1 marks a capital');
    t.isFalse(cities[1].capital, 'a missing cap flag is not a capital');
    t.isFalse(cities[1].megacity, 'a missing mega flag is not a megacity');
    t.isTrue(Math.abs(cities[0].projectionTerms[2] - Math.sin(GlobeMath.toRadians(2.5))) < 1e-9,
      'cities precompute sin(longitude) projection terms');

    t.equalNumber(0, GlobeWorldData.parseLand('not json').length,
      'invalid land JSON parses to an empty list');
    t.equalNumber(0, GlobeWorldData.parseCities('').length,
      'invalid cities JSON parses to an empty list');
    t.equalNumber(0, GlobeWorldData.parseBorders('{}').length,
      'a border document without geometries parses to an empty list');
  }

  // ---- GlobeCamera: opening state and selection sync ----
  {
    const camera: GlobeCamera = new GlobeCamera();
    camera.initialize(30, 40, 1, true);
    t.isTrue(Math.abs(camera.centerLat - 12) < 1e-12,
      'the zoomed-out opening starts at 40% of the target latitude');
    t.isTrue(Math.abs(camera.centerLon + 30) < 1e-12,
      'the zoomed-out opening starts 70 degrees west of the target');
    t.isTrue(Math.abs(camera.zoom - GlobeCamera.INTRO_START_ZOOM) < 1e-12,
      'the zoomed-out opening starts at INTRO_START_ZOOM');
    t.equalString('', camera.selectedGeohash,
      'the selection stays empty until the viewport is known');

    camera.setViewport(200, 800);
    t.equalString(Geohash.encode(12, -30, 1), camera.selectedGeohash,
      'the selection tracks the view center at the current precision');
    t.isTrue(Math.abs(camera.introEndZoom() -
      GlobeMath.thresholdZoomForPrecision(2, 200, 800) * GlobeCamera.INTRO_END_THRESHOLD_FRACTION) < 1e-9,
      'the intro lands a margin below the precision-2 threshold');
  }

  // ---- GlobeCamera: drag rotation and pinch zoom ----
  {
    const camera: GlobeCamera = new GlobeCamera();
    camera.initialize(0, 0, 1, false);
    camera.setViewport(200, 800);
    camera.rotateBy(10, 0);
    const expectedLon: number = -10 * 180 / (Math.PI * 200);
    t.isTrue(Math.abs(camera.centerLon - expectedLon) < 1e-9,
      'rotation moves longitude by 180/(pi*R) per pixel');
    t.isTrue(Math.abs(camera.centerLat) < 1e-12,
      'a horizontal drag does not move latitude');
    camera.rotateBy(0, 100000);
    t.isTrue(Math.abs(camera.centerLat - GlobeCamera.MAX_LAT) < 1e-9,
      'latitude clamps near the pole so polar cells stay selectable');

    const zoomCamera: GlobeCamera = new GlobeCamera();
    zoomCamera.initialize(0, 0, 1, false);
    zoomCamera.setViewport(400, 800);
    zoomCamera.zoomBy(5);
    t.equalNumber(2, zoomCamera.precision,
      'zooming in until level-2 cells span 22% of the screen reaches precision 2');
    t.isTrue(zoomCamera.canZoomOut, 'a precision above 1 can zoom out');
    zoomCamera.zoomBy(0.4);
    t.equalNumber(1, zoomCamera.precision,
      'zooming out drops back to precision 1');

    const minZoomCamera: GlobeCamera = new GlobeCamera();
    minZoomCamera.initialize(0, 0, 1, false);
    minZoomCamera.setViewport(200, 800);
    t.isFalse(minZoomCamera.canZoomOut,
      'a level-1 whole-globe view cannot zoom out further');
    minZoomCamera.zoomBy(1.02);
    t.isTrue(minZoomCamera.canZoomOut,
      'a level-1 view above the whole-globe tolerance can still zoom out');
  }

  // ---- GlobeCamera: flight plans ----
  {
    const camera: GlobeCamera = new GlobeCamera();
    camera.initialize(0, 0, 1, false);
    camera.setViewport(200, 800);

    const flight: GlobeFlightPlan | null = camera.planFlight(30, 60, 50, null, 550);
    t.isNotNull<GlobeFlightPlan>(flight, 'a flight across a large zoom change is planned');
    if (flight !== null) {
      t.isTrue(flight.durationMs >= 550, 'flight duration never drops below the minimum');
      const first: GlobeCameraSample = flight.sample(0);
      t.isTrue(Math.abs(first.lat) < 1e-6 && Math.abs(first.lon) < 1e-6 &&
        Math.abs(first.zoom - 1) < 1e-6,
        'the flight starts at the current camera state');
      const last: GlobeCameraSample = flight.sample(1);
      t.isTrue(Math.abs(last.lat - 30) < 1e-6 && Math.abs(last.lon - 60) < 1e-6 &&
        Math.abs(last.zoom - 50) < 1e-6,
        'the flight lands exactly on the target');
      camera.applyFlightSample(last);
      camera.finishFlight(flight);
      t.isTrue(Math.abs(camera.centerLat - 30) < 1e-9 &&
        Math.abs(camera.centerLon - 60) < 1e-9 && Math.abs(camera.zoom - 50) < 1e-9,
        'finishFlight pins the camera to the plan target');
      t.equalNumber(GlobeMath.autoPrecision(camera.globeRadiusPx, 800), camera.precision,
        'precision follows the landed zoom');
    }

    const glide: GlobeFlightPlan | null = camera.planFlight(10, 20, camera.zoom * 1.1, null, 400, true);
    t.isNotNull<GlobeFlightPlan>(glide, 'a glide plan is produced on demand');
    if (glide !== null) {
      const middle: GlobeCameraSample = glide.sample(0.5);
      t.isTrue(Math.abs(middle.lat - 20) < 1e-6,
        'a glide interpolates latitude linearly');
      t.isTrue(Math.abs(middle.lon - 40) < 1e-6,
        'a glide interpolates longitude linearly');
      t.isTrue(Math.abs(middle.zoom - camera.zoom * Math.sqrt(1.1)) < 1e-6,
        'a glide interpolates zoom exponentially');
    }

    t.isNull<GlobeFlightPlan>(new GlobeCamera().planFlight(0, 0, null, null, 550),
      'planFlight returns null before the viewport is known');
  }

  // ---- GlobeCamera: precision stepping ----
  {
    const camera: GlobeCamera = new GlobeCamera();
    camera.initialize(0, 0, 1, false);
    camera.setViewport(200, 800);
    t.isNull<number>(camera.targetZoomForPrecisionChange(1),
      'stepping to the current precision is a no-op');
    const zoom: number | null = camera.targetZoomForPrecisionChange(3);
    t.isNotNull<number>(zoom, 'stepping to a finer precision yields a target zoom');
    if (zoom !== null) {
      t.isTrue(Math.abs(zoom - GlobeMath.zoomForPrecision(3, 200, 800)) < 1e-9,
        'precision stepping frames the cell at a third of the screen');
    }
    t.isNull<GlobeFlightPlan>(camera.planZoomOut(),
      'zoom-out is refused at the whole globe on level 1');
  }

  // ---- GeohashPickerResult: join handoff ----
  {
    t.equalString('', GeohashPickerResult.takeJoinedGeohash(),
      'the join handoff starts empty');
    GeohashPickerResult.setJoinedGeohash('u4pruydq');
    t.equalString('u4pruydq', GeohashPickerResult.takeJoinedGeohash(),
      'the parked join result is returned once');
    t.equalString('', GeohashPickerResult.takeJoinedGeohash(),
      'taking the join result clears it');
  }
}
