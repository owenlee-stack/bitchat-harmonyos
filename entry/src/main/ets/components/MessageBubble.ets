/**
 * Chat message row renderer (T041): terminal / bubble dual-mode branch,
 * sender grouping, URL recognition.
 *
 * One component renders every timeline row of both chat surfaces
 * (PublicChatView timeline + PrivateChatView transcript):
 *  - bubbles mode (default, ChatState.bubblesMode = true): own messages
 *    right-aligned in an accent-tinted bubble with a tightened tail corner,
 *    others left-aligned with the sender header above the first bubble of
 *    their run (Android MessageComponents BubbleTextMessageLayout parity),
 *  - terminal mode (Matrix): flat left-aligned monospace lines, sender and
 *    time header above the body, no bubble shell,
 *  - system notices: centered narration lines that never group,
 *  - sender grouping: callers pass showSender (first-of-run) so consecutive
 *    messages from the same author hide the repeated header (Android
 *    MessageGrouping; system entries break groups in both directions).
 *
 * URL recognition follows the documented Text+ForEach+Span pattern
 * (FAQ faqs-arkui-1233 方案二): the body is split into plain-text and link
 * segments; link Spans are tinted and open the normalized URL through
 * UIAbilityContext.openLink (Android MessageInteractionUtils.normalizeUrl
 * parity: bare hosts get an https:// prefix).
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import EntryAbility from '../entryability/EntryAbility';

const DOMAIN = 0x0000;
const TAG = 'MessageBubble';

/** Body font size of bubble-mode message text. */
const BUBBLE_BODY_FONT_SIZE = 15;
/** Body font size of terminal-mode message text. */
const TERMINAL_BODY_FONT_SIZE = 14;

/** Link span tint (Android colorScheme.secondary role). */
const LINK_COLOR = '#64B5F6';

/** One rendered slice of a message body: plain text or a clickable URL. */
export class MessageSegment {
  readonly text: string;
  readonly isLink: boolean;
  /** Normalized open target ('' for plain segments). */
  readonly url: string;

  constructor(text: string, isLink: boolean, url: string) {
    this.text = text;
    this.isLink = isLink;
    this.url = url;
  }
}

/** Matches http(s):// and www. URLs up to the first whitespace. */
const URL_PATTERN: RegExp = /(?:https?:\/\/|www\.)[^\s]+/g;

/** Trailing punctuation stripped off a matched URL (kept as plain text). */
const URL_TRAILING_PUNCTUATION: string = '.,;:!?)]}\'"';

/** Prefix bare hosts (www.*) with https (Android normalizeMessageUrl parity). */
export function normalizeUrl(rawUrl: string): string {
  if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')) {
    return rawUrl;
  }
  return 'https://' + rawUrl;
}

/**
 * Split a message body into plain-text and clickable-URL segments (pure).
 * Degenerate matches (nothing left once trailing punctuation is stripped)
 * stay plain text; the stripped tail is kept as its own plain segment.
 */
export function splitMessageIntoSegments(content: string): MessageSegment[] {
  const segments: MessageSegment[] = [];
  const matches: RegExpMatchArray | null = content.match(URL_PATTERN);
  if (matches === null || matches.length === 0) {
    segments.push(new MessageSegment(content, false, ''));
    return segments;
  }
  let cursor: number = 0;
  for (let i: number = 0; i < matches.length; i++) {
    const rawMatch: string = matches[i];
    const start: number = content.indexOf(rawMatch, cursor);
    if (start < 0) {
      continue;
    }
    let urlEnd: number = rawMatch.length;
    while (urlEnd > 0 && URL_TRAILING_PUNCTUATION.indexOf(rawMatch.charAt(urlEnd - 1)) >= 0) {
      urlEnd--;
    }
    const schemePrefixLength: number = rawMatch.startsWith('http://') ? 'http://'.length :
      (rawMatch.startsWith('https://') ? 'https://'.length : 'www.'.length);
    if (start > cursor) {
      segments.push(new MessageSegment(content.substring(cursor, start), false, ''));
    }
    if (urlEnd <= schemePrefixLength) {
      segments.push(new MessageSegment(rawMatch, false, ''));
    } else {
      const url: string = rawMatch.substring(0, urlEnd);
      segments.push(new MessageSegment(url, true, normalizeUrl(url)));
      if (urlEnd < rawMatch.length) {
        segments.push(new MessageSegment(rawMatch.substring(urlEnd), false, ''));
      }
    }
    cursor = start + rawMatch.length;
  }
  if (cursor < content.length) {
    segments.push(new MessageSegment(content.substring(cursor), false, ''));
  }
  return segments;
}

@ComponentV2
export struct MessageBubble {
  /** Body text; embedded URLs become clickable spans. */
  @Param content: string = '';
  /** Own message: right side + accent bubble; others: left side. */
  @Param isMine: boolean = false;
  /** Narration line (system notice): centered, flat, never grouped. */
  @Param isSystem: boolean = false;
  /** First of a sender's run: render the sender/time header. */
  @Param showSender: boolean = true;
  @Param senderName: string = '';
  @Param timestampMs: number = 0;
  /** Surface mode (T041): messenger bubbles vs terminal/Matrix lines. */
  @Param bubblesMode: boolean = true;
  /** Bubble fill for own messages (context accent: public green / private blue). */
  @Param mineBackgroundColor: string = '#2E7D32';
  /** Bubble fill for other people's messages. */
  @Param othersBackgroundColor: string = '#2A2A2A';

  /** Link/plain span decomposition of the body, recomputed on content change. */
  @Computed
  get segments(): MessageSegment[] {
    return splitMessageIntoSegments(this.content);
  }

  build() {
    Column({ space: 3 }) {
      if (this.isSystem) {
        this.systemLine()
      } else {
        if (this.bubblesMode) {
          this.bubbleLayout()
        } else {
          this.terminalLayout()
        }
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  /** System notices are narration: centered, subdued, mode-independent. */
  @Builder
  private systemLine() {
    Text(this.content)
      .fontSize(12)
      .fontColor('#9E9E9E')
      .textAlign(TextAlign.Center)
      .width('100%')
      .padding({ top: 4, bottom: 4 })
  }

  /** Messenger rendering: own right with a tail, others left with a header. */
  @Builder
  private bubbleLayout() {
    Column({ space: 3 }) {
      if (this.showSender && !this.isMine) {
        Row({ space: 6 }) {
          Text(this.senderName)
            .fontSize(12)
            .fontColor('#B0BEC5')
          Text(MessageBubble.formatTime(this.timestampMs))
            .fontSize(10)
            .fontColor('#757575')
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
      }
      Text() {
        this.bodySpans(BUBBLE_BODY_FONT_SIZE, '#FFFFFF')
      }
      .fontSize(BUBBLE_BODY_FONT_SIZE)
      .fontColor('#FFFFFF')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .borderRadius({
        topLeft: 12,
        topRight: 12,
        bottomLeft: this.isMine ? 12 : 4,
        bottomRight: this.isMine ? 4 : 12
      })
      .backgroundColor(this.isMine ? this.mineBackgroundColor : this.othersBackgroundColor)
      .constraintSize({ maxWidth: '75%' })
      .alignSelf(this.isMine ? ItemAlign.End : ItemAlign.Start)
    }
    .width('100%')
  }

  /** Terminal/Matrix rendering: flat monospace lines, full width. */
  @Builder
  private terminalLayout() {
    Column({ space: 2 }) {
      if (this.showSender) {
        Row({ space: 6 }) {
          Text(MessageBubble.formatTime(this.timestampMs))
            .fontSize(12)
            .fontColor('#757575')
            .fontFamily('monospace')
          Text(this.senderName)
            .fontSize(12)
            .fontColor(this.isMine ? '#A5D6A7' : '#B0BEC5')
            .fontFamily('monospace')
        }
        .width('100%')
      }
      Text() {
        this.bodySpans(TERMINAL_BODY_FONT_SIZE, '#E0E0E0')
      }
      .fontSize(TERMINAL_BODY_FONT_SIZE)
      .fontColor('#E0E0E0')
      .fontFamily('monospace')
      .width('100%')
    }
    .width('100%')
  }

  /**
   * Plain/link span sequence shared by both layouts (Text + ForEach + Span,
   * FAQ faqs-arkui-1233 方案二). Link Spans open the normalized URL.
   */
  @Builder
  private bodySpans(fontSize: number, plainColor: string) {
    ForEach(this.segments, (segment: MessageSegment) => {
      if (segment.isLink) {
        Span(segment.text)
          .fontSize(fontSize)
          .fontColor(LINK_COLOR)
          .decoration({ type: TextDecorationType.Underline, color: LINK_COLOR })
          .onClick(() => {
            this.openUrl(segment.url);
          })
      } else {
        Span(segment.text)
          .fontSize(fontSize)
          .fontColor(plainColor)
      }
    }, (segment: MessageSegment, index: number) => index + ':' + segment.text)
  }

  /** Open a recognized link in the system browser; no-op before onCreate. */
  private openUrl(rawUrl: string): void {
    const context: common.UIAbilityContext | null = EntryAbility.getUiAbilityContext();
    if (context === null) {
      return;
    }
    context.openLink(rawUrl, { appLinkingOnly: false })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'openLink failed: %{public}s', JSON.stringify(error));
      });
  }

  private static formatTime(timestampMs: number): string {
    const date: Date = new Date(timestampMs);
    return MessageBubble.pad2(date.getHours()) + ':' + MessageBubble.pad2(date.getMinutes());
  }

  private static pad2(value: number): string {
    return value < 10 ? '0' + value : '' + value;
  }
}
