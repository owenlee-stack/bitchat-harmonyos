/**
 * QR identity-verification sheet (US11, T057; Android VerificationSheet
 * parity).
 *
 * Shows the signed "my QR" deep link (ScanKit generateBarcode; the QR
 * string is built + cached by VerificationService.buildMyQRString), scans
 * the peer's QR with the system scan UI (ScanKit scanBarcode) and feeds
 * the result into ChatViewModel.beginQRVerification, which fires the
 * 0x10/0x11 Noise challenge/response handshake. A verified peer shows
 * the 已验证 status and offers 取消验证.
 */
import { generateBarcode, scanBarcode, scanCore } from '@kit.ScanKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatState } from '../viewmodel/ChatState';
import { ChatViewModel } from '../viewmodel/ChatViewModel';

const DOMAIN = 0x0000;
const TAG = 'VerificationSheet';

/** Generated QR pixel size (px; ScanKit recommends [200, 4096]). */
const QR_SIZE_PX = 480;

@ComponentV2
export struct VerificationSheet {
  @Param conversationId: string = '';
  @Event onClose: () => void = (): void => {};
  @Local chatState: ChatState = ChatViewModel.getInstance().state;
  @Local qrImage: image.PixelMap | null = null;
  @Local qrFailed: boolean = false;
  @Local scanFeedback: string = '';

  @Computed
  get verified(): boolean {
    return this.conversationId !== '' &&
      ChatViewModel.getInstance().isConversationVerified(this.conversationId);
  }

  @Computed
  get verificationInFlight(): boolean {
    return this.chatState.verificationPendingPeerId !== '' &&
      this.chatState.verificationPendingPeerId === this.conversationId;
  }

  aboutToAppear(): void {
    this.generateQr();
  }

  build() {
    Column({ space: 0 }) {
      Row({ space: 10 }) {
        Text('身份验证')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
        Text('关闭')
          .fontSize(14)
          .fontColor('#64B5F6')
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 12 })

      Scroll() {
        Column({ space: 14 }) {
          Text(this.statusText())
            .fontSize(13)
            .fontColor(this.statusColor())

          Column() {
            if (this.qrImage !== null) {
              Image(this.qrImage)
                .width(220)
                .height(220)
                .interpolation(ImageInterpolation.High)
            } else if (this.qrFailed) {
              Text('二维码生成失败')
                .fontSize(13)
                .fontColor('#E57373')
                .padding(30)
            } else {
              LoadingProgress()
                .width(40)
                .height(40)
                .color('#64B5F6')
                .padding(20)
            }
          }
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding(10)

          Text('让对方扫描此二维码，或扫描对方的二维码完成双向验证')
            .fontSize(12)
            .fontColor('#8D949B')
            .textAlign(TextAlign.Center)

          Button(this.scanActionLabel())
            .fontSize(15)
            .width('70%')
            .backgroundColor('#1565C0')
            .onClick(() => {
              void this.scanPeerQr();
            })

          if (this.scanFeedback !== '') {
            Text(this.scanFeedback)
              .fontSize(12)
              .fontColor('#B0BEC5')
              .textAlign(TextAlign.Center)
          }

          if (this.verified) {
            Button('取消验证')
              .fontSize(15)
              .width('70%')
              .backgroundColor('#455A64')
              .onClick(() => {
                ChatViewModel.getInstance().unverifyConversation(this.conversationId);
              })
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 8, bottom: 24 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#121212')
  }

  /** Render the signed "my QR" deep link through ScanKit. */
  private generateQr(): void {
    const qrString: string | null = ChatViewModel.getInstance().buildMyVerificationQR();
    if (qrString === null) {
      this.qrFailed = true;
      return;
    }
    const options: generateBarcode.CreateOptions = {
      scanType: scanCore.ScanType.QR_CODE,
      height: QR_SIZE_PX,
      width: QR_SIZE_PX
    };
    generateBarcode.createBarcode(qrString, options)
      .then((pixelMap: image.PixelMap): void => {
        this.qrImage = pixelMap;
      })
      .catch((error: BusinessError): void => {
        this.qrFailed = true;
        hilog.error(DOMAIN, TAG, 'QR generation failed: %{public}s', error.message);
      });
  }

  /** System scan UI -> beginQRVerification (0x10 handshake). */
  private async scanPeerQr(): Promise<void> {
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.QR_CODE]
    };
    try {
      const result: scanBarcode.ScanResult =
        await scanBarcode.startScanForResult(getContext(this), options);
      const started: boolean =
        ChatViewModel.getInstance().beginQRVerification(result.originalValue);
      this.scanFeedback = started ? '已发起验证，等待对方响应…' :
        '二维码无效或未找到对应用户';
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 1000500002) {
        // User canceled the scan UI; keep the previous feedback.
        return;
      }
      this.scanFeedback = '扫码失败：' + err.message;
    }
  }

  private statusText(): string {
    if (this.verified) {
      return '已验证 · 此对端的 Noise 密钥指纹与扫码结果一致';
    }
    if (this.verificationInFlight) {
      return '验证中 · 正在等待对方响应…';
    }
    return '未验证 · 双方互扫二维码以确认身份';
  }

  private statusColor(): string {
    if (this.verified) {
      return '#81C784';
    }
    if (this.verificationInFlight) {
      return '#FFB300';
    }
    return '#8D949B';
  }

  private scanActionLabel(): string {
    return this.verified ? '重新扫码验证' : '扫描对方二维码';
  }
}
