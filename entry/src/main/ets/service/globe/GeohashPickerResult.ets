/**
 * Join-result handoff for the geohash picker (T067, US13).
 *
 * HarmonyOS has no activity result contract, so the picker page (a separate
 * router page) parks the geohash the user joined here before navigating
 * back; the location-channel surface that integrates the picker (T068)
 * consumes it with takeJoinedGeohash. Pure ArkTS: host-runnable.
 */
export class GeohashPickerResult {
  private static joinedGeohash: string = '';

  /** Parks the geohash picked on the globe before router.back(). */
  static setJoinedGeohash(geohash: string): void {
    GeohashPickerResult.joinedGeohash = geohash;
  }

  /** Returns and clears the pending join result. */
  static takeJoinedGeohash(): string {
    const result: string = GeohashPickerResult.joinedGeohash;
    GeohashPickerResult.joinedGeohash = '';
    return result;
  }
}
