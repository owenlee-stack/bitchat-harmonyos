/**
 * Scrolling live waveform (US14, T070; Android
 * RealtimeScrollingWaveform.kt parity): renders the trailing window of
 * normalized [0,1] amplitude samples as bars that stream in from the
 * right edge while older history scrolls off the left. Presentational
 * only - the samples arrive through ChatState (T054 capture poll or the
 * US14 live-voice receive listener) and stay bounded by the caller.
 */
const DEFAULT_BAR_COUNT = 48;
const DEFAULT_MIN_BAR_VP = 3;
const DEFAULT_MAX_BAR_VP = 24;

@ComponentV2
export struct RealtimeWaveform {
  /** Normalized [0,1] samples, oldest first (newest bar is rightmost). */
  @Param samples: number[] = [];
  /** Maximum rendered bars; older samples drop off the left edge. */
  @Param barCount: number = DEFAULT_BAR_COUNT;
  @Param minBarVp: number = DEFAULT_MIN_BAR_VP;
  @Param maxBarVp: number = DEFAULT_MAX_BAR_VP;
  @Param fillColor: string = '#E57373';

  @Computed
  get visibleBars(): number[] {
    const count: number = Math.max(1, Math.floor(this.barCount));
    if (this.samples.length <= count) {
      return this.samples;
    }
    return this.samples.slice(this.samples.length - count);
  }

  build() {
    Row({ space: 2 }) {
      ForEach(this.visibleBars, (value: number) => {
        Rect()
          .width(3)
          .height(RealtimeWaveform.barHeightOf(value, this.minBarVp, this.maxBarVp))
          .radius(1.5)
          .fill(this.fillColor)
      }, (value: number, index: number) => index + '_' + value)
    }
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.End)
    .height(Math.max(this.maxBarVp, this.minBarVp))
    .layoutWeight(1)
  }

  /** Bar height in vp, clamped into the [minBarVp, maxBarVp] range. */
  private static barHeightOf(value: number, minBarVp: number,
    maxBarVp: number): number {
    const clamped: number = Math.min(Math.max(value, 0), 1);
    const low: number = Math.min(minBarVp, maxBarVp);
    const high: number = Math.max(minBarVp, maxBarVp);
    return low + Math.round(clamped * (high - low));
  }
}
