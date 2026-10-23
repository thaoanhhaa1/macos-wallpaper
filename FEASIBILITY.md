# Phase 0 — Báo cáo feasibility surface strategy

Trạng thái: **hoàn thành phần spike và quyết định strategy; manual matrix còn các mục đánh dấu
PENDING**.

Spike code: [`WallpaperSpike/`](WallpaperSpike)  
Self-test report: [`Build/feasibility-report.json`](Build/feasibility-report.json)  
Hướng dẫn build/run: [`README.md`](README.md)

---

## 1. Mục tiêu

Trả lời sớm câu hỏi rủi ro nhất của dự án: **có thể đặt video phía sau desktop icons bằng API
công khai trên macOS mục tiêu hay không?** Nếu không, phải chốt fallback trước khi làm UI,
persistence và playback engine đầy đủ.

Phạm vi spike:

- Tạo app macOS tối giản bằng SwiftUI + AppKit.
- Phát video bằng AVFoundation.
- Tạo borderless window ở các window level khác nhau trên một hoặc nhiều display.
- Kiểm tra window ordering so với Finder desktop icons, system wallpaper, Dock/menu bar.
- Kiểm tra playback, loop, screen/display monitoring và sleep/wake hooks.
- Ghi lại giới hạn của API công khai và quyết định surface strategy.

---

## 2. Môi trường kiểm thử

| Hạng mục | Giá trị |
| --- | --- |
| macOS | 27.0 (26A428) |
| Kiến trúc | arm64 |
| Xcode / Swift | Xcode 27.1 / Swift 6.4 |
| Display 1 | Built-in Retina, 3024×1964 px, scale 2.0×, 120 Hz |
| Display 2 | S27R35x, 1920×1080 px, scale 1.0×, 75 Hz |
| Test video | 1280×720, 4.00 s, 30 fps, H.264, không audio |

Self-test chạy trên `NSScreen.main` tại thời điểm chạy. Kết quả dưới đây lấy từ
`Build/feasibility-report.json` (generated `2026-10-23T04:36:15Z`, duration 15.1 s).

---

## 3. Cách reproduce

```bash
# build
./Scripts/build.sh

# self-test: tạo fixture, thử level, probe window ordering, test loop
./Scripts/self-test.sh

# demo thủ công (quan trọng: xác nhận bằng mắt trên màn hình vật lý)
./Scripts/demo.sh belowDesktopIcons 1 25

# chẩn đoán screen-capture (không phải nguồn quyết định cuối cùng)
./Scripts/visibility-check.sh 5
```

Terminal cần quyền Screen Recording cho `visibility-check.sh`.

---

## 4. Kết quả tự động

### 4.1 Window level và ordering

Trên host này:

- `desktopWindow` = `-2147483623`
- `desktopIconWindow` = `-2147483603`
- System wallpaper thực tế nằm ở layer `-2147483624` / `-2147483625`
  (`WindowManager "Wallpaper"`, `Wallpaper "Offscreen Wallpaper Window"`).

| Strategy | Level | Vị trí so với desktop icons | Vị trí so với system wallpaper | Playback |
| --- | ---: | --- | --- | --- |
| `belowDesktopIcons` | `-2147483604` | **BÊN DƯỚI icons** | **BÊN TRÊN wallpaper** | playing, rate 1.0 |
| `aboveDesktopPicture` | `-2147483622` | **BÊN DƯỚI icons** | **BÊN TRÊN wallpaper** | playing, rate 1.0 |
| `justBelowNormal` | `-1` | BÊN TRÊN icons | BÊN TRÊN wallpaper | playing, rate 1.0 |
| `normal` | `0` | BÊN TRÊN icons | BÊN TRÊN wallpaper | playing, rate 1.0 |

Ví dụ `belowDesktopIcons`:

```text
surface layer=-2147483604 order=58
frontmost desktop-icon window order=57
surface is BELOW desktop icons
surface is ABOVE the system wallpaper
```

`CGWindowListCopyWindowInfo` xác nhận surface:

- có mặt trong on-screen window list;
- có đúng layer mong muốn;
- có `alpha = 1.0`, `isOnScreen = true`;
- nằm sau Finder icon window và trước system wallpaper window.

### 4.2 Playback và loop

- AVPlayer `rate = 1.0`, `currentTime` tăng sau 1.2 s ở mọi strategy.
- Loop trial với video 4 s:
  - first sample: `t=3.49 s`, rate 1.0
  - second sample: `t=1.71 s`, rate 1.0
  - `wrapped = true`
- Demo 25 s chạy qua nhiều vòng clip 4 s liên tiếp; `occlusionState.visible = yes` ở mọi mẫu,
  rate giữ 1.0, không thấy player dừng.
- Self-test không đo được black frame tại thời điểm loop; cần kiểm tra bằng mắt với clip ngắn.

### 4.3 Multi-display

Self-test tạo surface riêng cho từng display, tại `belowDesktopIcons`, và probe từng window:

| Display | Scale | Playback | Behind icons | Above wallpaper |
| --- | ---: | --- | --- | --- |
| Built-in Retina Display (1) | 2.0× | playing, t≈1.24 s | true | true |
| S27R35x (2) | 1.0× | playing, t≈1.25 s | true | true |

Hai display có scale factor khác nhau (2.0× và 1.0×); surface tạo đúng theo
`CGDirectDisplayID` và giữ ordering trên cả hai. Đây là kiểm tra tự động; xác nhận visual trên
display ngoài vẫn nằm trong manual matrix.

### 4.4 Xác nhận bằng mắt

Đã chạy `./Scripts/demo.sh belowDesktopIcons 1 25` trên built-in display:

- **Video hiển thị phía sau desktop icons**.
- Đây là xác nhận quyết định: strategy `belowDesktopIcons` hoạt động trên macOS 27.

### 4.5 Giới hạn của screen capture trên macOS 27

`Scripts/visibility-check.sh` (ScreenCaptureKit/screencapture) cho kết quả:

| Strategy | Kết quả capture |
| --- | --- |
| `belowDesktopIcons` | NOT_VISIBLE (~1.3% bright pixels) |
| `aboveDesktopPicture` | NOT_VISIBLE (~1.4% bright pixels) |
| `justBelowNormal` | NOT_VISIBLE (~4.3% bright pixels) |
| `normal` | VISIBLE (~50.8% bright pixels) |

Trong khi đó:

- capture riêng window surface (`screencapture -l <windowNumber>`) hiển thị đúng color bars;
- `occlusionState` báo `visible = true` cho window level âm;
- người dùng xác nhận video hiển thị thật trên màn hình.

Kết luận: **trên macOS 27, screen capture bỏ qua third-party window ở level âm** dù window vẫn
hiển thị. Đây là giới hạn của công cụ test/automation, không phải lỗi sản phẩm. Không dùng
screenshot làm tiêu chí pass/fail duy nhất cho surface; phải xác nhận trên màn hình vật lý.

---

## 5. Bảng compatibility

| Hạng mục | Cách kiểm tra | Kết quả | Ghi chú |
| --- | --- | --- | --- |
| Window level `belowDesktopIcons` trên macOS 27 | self-test + mắt | **PASS** | Video nằm sau icons, trên system wallpaper |
| Window level `aboveDesktopPicture` trên macOS 27 | self-test | PASS (ordering) | Chưa xác nhận bằng mắt; giữ làm phương án so sánh |
| Playback AVPlayer + loop | self-test | **PASS** | `AVPlayerLooper`, rate 1.0, thời gian quay vòng |
| Hiển thị trên display 2 (1.0×) | demo | PENDING | Cần xác nhận bằng mắt |
| Nhiều display, scale khác nhau | self-test multi-display trial | **PASS (automated)** | Surface + playback + ordering đúng trên 2 display 2.0×/1.0×; visual trên display ngoài PENDING |
| Desktop icons | manual | PENDING | Cần select/drag/open icon khi surface chạy |
| Finder context menu | manual | PENDING | Right-click desktop trống |
| Click-through / selection rectangle | manual | PENDING | Kéo chọn icon xuyên qua surface |
| Focus bàn phím / Cmd+Tab | manual | PENDING | Surface không được thành key/main |
| Spaces | manual | PENDING | `canJoinAllSpaces` đã cấu hình |
| Mission Control | manual | PENDING | Surface không được hiện như window |
| Fullscreen app | manual | PENDING | `fullScreenNone` đã cấu hình |
| Display/system sleep + wake | manual | PENDING | Code observe `NSWorkspace` notifications |
| Display hot-plug | manual | PENDING | Code observe `didChangeScreenParametersNotification` |
| Finder relaunch | manual | PENDING | Surface phải giữ ordering |
| Screen lock/unlock | manual | PENDING | Playback phải resume đúng |
| System wallpaper bị lộ / nháy | manual | PENDING | Kiểm tra loop boundary và display change |
| macOS 14/15 | chưa có máy test | PENDING | Cùng public API; phải chạy lại self-test trước release |
| Sandbox / signing / notarization | ngoài Phase 0 | N/A | Phase 8 |

---

## 6. Quyết định kiến trúc surface

### Strategy chính

Dùng một `NSWindow` borderless cho mỗi display, đặt ở level:

```swift
NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
```

Cấu hình:

- `styleMask = [.borderless]`
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]`
- `isOpaque = true`, `backgroundColor = .black`, `hasShadow = false`
- `ignoresMouseEvents = true` (click-through mặc định)
- `canBecomeKey = false`, `canBecomeMain = false`
- `hidesOnDeactivate = false`, `canHide = false`
- `constrainFrameRect` trả về nguyên frame để window phủ cả vùng menu bar
- `orderFrontRegardless()`, sau đó `setFrame(screen.frame, display: true)`
- Nội dung là `AVPlayerLayer` trong `NSView`; playback dùng `AVQueuePlayer` +
  `AVPlayerLooper`, mute mặc định, không giữ display thức.

Level được tập trung trong `SurfaceLevelStrategy`; không hard-code rải rác.

### Phương án dự phòng gần

`aboveDesktopPicture` (`desktopWindow + 1`) cũng đã pass window ordering. Giữ lại trong enum để
có thể chuyển nhanh nếu một bản macOS sau thay đổi hành vi compositing của `desktopIconWindow - 1`.

### Fallback khi public API không còn hoạt động

Theo PLAN, fallback được chấp nhận là:

1. **Normal-level click-through overlay** (`level = 0`): video hiển thị nhưng **che desktop
   icons**; phải thêm cơ chế hide/pause khi người dùng tương tác desktop và ghi rõ giới hạn.
2. **Main-display-only** với thông báo rõ, nếu đa màn hình không ổn định.
3. Không dùng private API, không inject WindowServer, không phá SIP.

Nếu chọn App Store, phải đánh giá lại vì có thể phát sinh hạn chế sandbox/window/display.

---

## 7. Tiêu chí fallback

Chuyển sang fallback nếu bất kỳ điều kiện nào sau đây xảy ra trên macOS mục tiêu:

1. Video không hiển thị được **phía sau desktop icons** trên màn hình vật lý với cả
   `belowDesktopIcons` và `aboveDesktopPicture`.
2. Desktop icons, Finder context menu, selection rectangle hoặc keyboard focus bị surface
   chặn/làm hỏng.
3. Window ordering trôi sau Spaces/Mission Control/Finder relaunch/app activation và không
   ổn định được bằng re-order/level adjustment.
4. Hiển thị đúng nhưng gây nháy system wallpaper đáng kể ở loop boundary hoặc display change.
5. API công khai bị loại bỏ/không còn hiệu lực và không có entitlement công khai thay thế.

Khi fallback được kích hoạt, phải:

- ghi rõ degraded behavior trong README/release notes;
- thêm toggle “overlay mode” thay vì âm thầm đổi hành vi;
- giữ code surface tập trung để có thể đổi strategy mà không ảnh hưởng playback/persistence;
- chạy lại self-test + manual matrix trên mọi version macOS hỗ trợ.

---

## 8. Giới hạn đã biết

- Screen capture trên macOS 26+ bỏ qua third-party window level âm; đây là **test limitation**.
- `CGWindowListCopyWindowInfo` ordering là điều kiện cần, không đủ; phải xác nhận bằng mắt.
- Chưa đo black frame tại loop boundary; `AVPlayerLooper` được kỳ vọng là gapless nhưng cần
  kiểm tra visual với clip ngắn.
- Chưa kiểm tra manual Spaces, Mission Control, fullscreen, sleep/wake, hot-plug, Finder relaunch.
- Chưa có persistence/bookmark, launch at login, sandbox, signing, notarization.
- Multi-display mới ở mức enumerate và tạo surface theo display; chưa có UI mapping đầy đủ.
- Resource policy đã có (fullscreen/battery/Low Power Mode/sleep/thermal), nhưng chưa có soak test
  dài hạn và chưa đo dropped frames trên phần cứng/1080p/4K thực tế.
- `currentTime`/loop check phụ thuộc thời gian sleep của self-test; không phải phép đo chính xác
  về frame timing.

---

## 9. Manual checklist còn lại

Đánh dấu sau khi chạy `Scripts/demo.sh` và thao tác trên desktop:

- [x] Video hiển thị phía sau desktop icons trên built-in display (macOS 27,
      `belowDesktopIcons`).
- [ ] Video hiển thị đúng trên display ngoài (1.0×).
- [ ] Select / drag / open desktop icons.
- [ ] Right-click desktop trống → Finder context menu.
- [ ] Kéo selection rectangle qua vùng video.
- [ ] Click app khác, gõ phím, Cmd+Tab; surface không nhận focus.
- [ ] Chuyển Spaces (Ctrl+←/→ và swipe).
- [ ] Mission Control: surface không hiện như window.
- [ ] Fullscreen app: surface bị che, quay lại đúng sau khi thoát.
- [ ] Display sleep/wake và system sleep/wake: pause/resume không treo player.
- [ ] Cắm/rút display: không orphan window, surface mới đúng vị trí.
- [ ] `killall Finder`: surface vẫn nằm sau icons.
- [ ] Lock/unlock: playback resume đúng.
- [ ] Loop boundary: không thấy black frame rõ rệt.
- [ ] App activation/Dock/menu bar: ordering không đổi.
- [ ] Đã ghi nhận capture exclusion và không dùng screenshot làm pass/fail duy nhất.

---

## 10. Ảnh hưởng tới các pha tiếp theo

- **Phase 1**: giữ `SurfaceLevelStrategy`, `WallpaperSurfaceWindow`, `DisplayProbe`,
  `WindowProbe` làm nền; thêm OSLog convention và fixture video (đã có test pattern generator).
- **Phase 3**: dùng `belowDesktopIcons` làm default; thêm manual smoke test bắt buộc trước khi
  release; giữ `aboveDesktopPicture` và `normal` làm fallback có kiểm soát.
- **Phase 5**: mở rộng `DisplayCoordinator` theo `CGDirectDisplayID`; test 1.0×/2.0×, mirrored,
  hot-plug và Spaces.
- **Phase 6**: bổ sung resource policy; không dùng display capture để đo visibility.
- **Phase 8**: đánh giá lại screen recording/capture, sandbox và kênh phân phối trước khi chốt.

---

## 11. Artifacts

- `WallpaperSpike/WallpaperSpike.xcodeproj`
- `WallpaperSpike/WallpaperSpike/**` — spike code
- `Scripts/build.sh`, `run-spike.sh`, `self-test.sh`, `demo.sh`, `visibility-check.sh`
- `Tools/display-capture.swift`
- `Build/feasibility-report.json` — kết quả self-test
- `Build/visibility/**` — screenshot và stats của visibility check (mang tính chẩn đoán)
