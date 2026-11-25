/**
 * Bundled Natural Earth world geometry for the globe picker (T067, US13).
 *
 * Port of the Android LandData.kt: loads the public-domain 110m land
 * polygons, admin-0 border lines and populated places from the bundled
 * GeoJSON assets and exposes them as flat rings of (lat, lon) pairs with
 * precomputed sin/cos projection terms. Parsing is pure ArkTS (text in,
 * typed structures out) so the host contract runner can exercise it; the
 * device page supplies the rawfile text.
 */
import { GlobeMath } from './GlobeMath';

/** One closed polygon ring: interleaved (lat, lon) pairs plus projection terms. */
export class GlobeRing {
  readonly coords: Float32Array;
  readonly size: number;
  /** Per-point sin(lat), cos(lat), sin(lon), cos(lon). */
  readonly projectionTerms: Float32Array;

  constructor(coords: Float32Array, size: number) {
    this.coords = coords;
    this.size = size;
    this.projectionTerms = GlobeWorldData.prepareProjectionTerms(coords, size);
  }
}

/** One populated place with display rank and flags. */
export class GlobeCity {
  readonly name: string;
  readonly lat: number;
  readonly lon: number;
  readonly rank: number;
  readonly capital: boolean;
  readonly megacity: boolean;
  readonly projectionTerms: Float32Array;

  constructor(name: string, lat: number, lon: number, rank: number,
    capital: boolean, megacity: boolean) {
    this.name = name;
    this.lat = lat;
    this.lon = lon;
    this.rank = rank;
    this.capital = capital;
    this.megacity = megacity;
    const coords: Float32Array = new Float32Array(2);
    coords[0] = lat;
    coords[1] = lon;
    this.projectionTerms = GlobeWorldData.prepareProjectionTerms(coords, 1);
  }
}

export class GlobeWorldData {
  /** Parses world_land.geojson into polygon rings. */
  static parseLand(text: string): GlobeRing[] {
    const rings: GlobeRing[] = [];
    const geometries: Object[] | null = GlobeWorldData.extractGeometries(text);
    if (geometries === null) {
      return rings;
    }
    for (let i: number = 0; i < geometries.length; i++) {
      const geom: Record<string, Object> = geometries[i] as Record<string, Object>;
      const type: Object | undefined = geom['type'];
      if (typeof type !== 'string') {
        continue;
      }
      const coordinates: Object | undefined = geom['coordinates'];
      if (coordinates === undefined || typeof coordinates !== 'object') {
        continue;
      }
      if (type === 'Polygon') {
        GlobeWorldData.parsePolygonRings(coordinates as number[][][], rings);
      } else if (type === 'MultiPolygon') {
        const polygons: number[][][][] = coordinates as number[][][][];
        for (let j: number = 0; j < polygons.length; j++) {
          GlobeWorldData.parsePolygonRings(polygons[j], rings);
        }
      }
    }
    return rings;
  }

  /** Parses world_borders.geojson into open line rings. */
  static parseBorders(text: string): GlobeRing[] {
    const lines: GlobeRing[] = [];
    const geometries: Object[] | null = GlobeWorldData.extractGeometries(text);
    if (geometries === null) {
      return lines;
    }
    for (let i: number = 0; i < geometries.length; i++) {
      const geom: Record<string, Object> = geometries[i] as Record<string, Object>;
      const type: Object | undefined = geom['type'];
      if (typeof type !== 'string') {
        continue;
      }
      const coordinates: Object | undefined = geom['coordinates'];
      if (coordinates === undefined || typeof coordinates !== 'object') {
        continue;
      }
      if (type === 'LineString') {
        GlobeWorldData.parseLinePoints(coordinates as number[][], lines);
      } else if (type === 'MultiLineString') {
        const parts: number[][][] = coordinates as number[][][];
        for (let j: number = 0; j < parts.length; j++) {
          GlobeWorldData.parseLinePoints(parts[j], lines);
        }
      }
    }
    return lines;
  }

  /** Parses world_cities.geojson into city records. */
  static parseCities(text: string): GlobeCity[] {
    const cities: GlobeCity[] = [];
    let root: Record<string, Object> | null = null;
    try {
      root = JSON.parse(text) as Record<string, Object>;
    } catch (e) {
      return cities;
    }
    if (root === null || typeof root !== 'object') {
      return cities;
    }
    const rawCities: Object | undefined = root['cities'];
    if (rawCities === undefined || typeof rawCities !== 'object' || !Array.isArray(rawCities)) {
      return cities;
    }
    const entries: Object[] = rawCities as Object[];
    for (let i: number = 0; i < entries.length; i++) {
      const entry: Record<string, Object> = entries[i] as Record<string, Object>;
      const name: Object | undefined = entry['n'];
      const lat: Object | undefined = entry['lat'];
      const lon: Object | undefined = entry['lon'];
      const rank: Object | undefined = entry['r'];
      if (typeof name !== 'string' || typeof lat !== 'number' ||
        typeof lon !== 'number' || typeof rank !== 'number') {
        continue;
      }
      const capRaw: Object | undefined = entry['cap'];
      const megaRaw: Object | undefined = entry['mega'];
      cities.push(new GlobeCity(name, lat, lon, Math.trunc(rank),
        typeof capRaw === 'number' && capRaw === 1,
        typeof megaRaw === 'number' && megaRaw === 1));
    }
    return cities;
  }

  private static extractGeometries(text: string): Object[] | null {
    let root: Record<string, Object> | null = null;
    try {
      root = JSON.parse(text) as Record<string, Object>;
    } catch (e) {
      return null;
    }
    if (root === null || typeof root !== 'object') {
      return null;
    }
    const geometries: Object | undefined = root['geometries'];
    if (geometries === undefined || typeof geometries !== 'object' || !Array.isArray(geometries)) {
      return null;
    }
    return geometries as Object[];
  }

  private static parsePolygonRings(ringsJson: number[][][], out: GlobeRing[]): void {
    for (let r: number = 0; r < ringsJson.length; r++) {
      const ringJson: number[][] = ringsJson[r];
      const n: number = ringJson.length;
      if (n < 3) {
        continue;
      }
      const coords: Float32Array = new Float32Array(n * 2);
      for (let p: number = 0; p < n; p++) {
        const point: number[] = ringJson[p];
        if (point.length < 2) {
          continue;
        }
        coords[p * 2] = point[1]; // lat
        coords[p * 2 + 1] = point[0]; // lon
      }
      out.push(new GlobeRing(coords, n));
    }
  }

  private static parseLinePoints(lineJson: number[][], out: GlobeRing[]): void {
    const n: number = lineJson.length;
    if (n < 2) {
      return;
    }
    const coords: Float32Array = new Float32Array(n * 2);
    for (let p: number = 0; p < n; p++) {
      const point: number[] = lineJson[p];
      if (point.length < 2) {
        continue;
      }
      coords[p * 2] = point[1]; // lat
      coords[p * 2 + 1] = point[0]; // lon
    }
    out.push(new GlobeRing(coords, n));
  }

  static prepareProjectionTerms(coords: Float32Array, size: number): Float32Array {
    const terms: Float32Array = new Float32Array(size * 4);
    for (let index: number = 0; index < size; index++) {
      const latRadians: number = GlobeMath.toRadians(coords[index * 2]);
      const lonRadians: number = GlobeMath.toRadians(coords[index * 2 + 1]);
      terms[index * 4] = Math.sin(latRadians);
      terms[index * 4 + 1] = Math.cos(latRadians);
      terms[index * 4 + 2] = Math.sin(lonRadians);
      terms[index * 4 + 3] = Math.cos(lonRadians);
    }
    return terms;
  }
}
