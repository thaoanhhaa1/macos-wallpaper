# Wallpaper for macOS

Ứng dụng macOS native dùng video làm hình nền động. Repo hiện có hai phần:

- `WallpaperSpike/` — feasibility spike của Pha 0.
- `WallpaperApp/` — ứng dụng thật, hiện hoàn thành Pha 1 đến Pha 8.

Quyết định kỹ thuật và bảng compatibility nằm trong [`FEASIBILITY.md`](FEASIBILITY.md);
phạm vi các pha tiếp theo nằm trong [`PLAN.md`](PLAN.md).

## Yêu cầu

- macOS 14 trở lên (đã chạy thực tế trên macOS 27.0, arm64).
- Xcode 27 / Swift 6 toolchain.
- Terminal cần quyền **Screen Recording** nếu chạy `Scripts/visibility-check.sh`.

## Ứng dụng

### Build và chạy

```bash
./Scripts/build-app.sh    # build Debug, in ra đường dẫn .app
./Scripts/run-app.sh      # build rồi mở app
```

App chạy dạng menu bar utility (`LSUIElement = YES`), không có Dock icon. Lần chạy đầu
tiên sẽ mở Settings một lần; các lần sau mở lại bằng item **Settings…** trên menu bar.

Bundle identifier: `com.local.wallpaperapp`. Debug dùng ad-hoc signing để phát triển;
Release bật hardened runtime và được ký bằng Developer ID qua quy trình trong
[`DISTRIBUTION.md`](DISTRIBUTION.md). App Sandbox tắt cho kênh Developer ID; entitlements
sandbox đã chuẩn bị trong `WallpaperApp/WallpaperApp-Sandbox.entitlements` cho nhánh
Mac App Store.

Build và phân phối release:

```bash
DEVELOPMENT_TEAM=ABCDE12345 ./Scripts/release.sh   # Build/Wallpaper.dmg đã notarize
./Scripts/verify-release.sh Build/Wallpaper.dmg
```

### Phạm vi Phase 2

- Menu bar shell với trạng thái wallpaper, Play/Pause, Mute/Unmute, Choose Video,
  Settings, About và Quit.
- Open panel lọc MP4/MOV; validation bất đồng bộ bằng `AVAsset` (playable, video track,
  duration, kích thước, frame rate, codec, audio).
- Hiển thị metadata và lỗi có thể hành động cho từng trạng thái import.
- Preview bằng `AVPlayerLayer` trong Settings.
- Playback engine dùng `AVQueuePlayer` + `AVPlayerLooper`: play/pause, seek, restart,
  mute, volume, bật/tắt loop; teardown player, looper và observer khi thay media.
- Settings window với danh sách display hiện tại, surface strategy và thông tin chẩn đoán.
- App lifecycle dùng SwiftUI `App` + `AppDelegate`/AppKit integration.
- Module/folder structure theo kiến trúc trong `PLAN.md`.
- `OSLog` subsystem và quy ước log.
- Fixture video nhỏ cho development/test, xem trực tiếp từ mục Development.

Chưa nằm trong Phase 2: persistence của media đã chọn, multi-display configuration UI,
launch at login.

### Phạm vi Phase 3

- Surface controller tạo borderless window ở `desktopIconWindow − 1` cho display đang chọn,
  dùng `NSScreen.frame` theo strategy đã xác minh ở Pha 0.
- `collectionBehavior` gồm `canJoinAllSpaces`, `stationary`, `ignoresCycle`,
  `fullScreenNone`; window không nhận key/main focus và bỏ qua mouse events.
- Playback của surface tách khỏi rendering: một `SurfacePlayback` dùng chung cho các
  surface, mỗi window chỉ gắn `AVPlayerLayer`.
- Apply / Remove / Restore Last Wallpaper có trong Settings và menu bar.
- Settings playback (mute, volume, loop, scaling) được áp dụng lại cho surface.
- Surface tự cập nhật frame khi display thay đổi và re-assert ordering khi app activate,
  Finder activate hoặc Finder relaunch.
- Copy Diagnostics có thêm trạng thái surface, số window và display mode.

### Kiểm tra wallpaper surface thủ công

- Chọn video, bấm **Apply as Wallpaper**: video nằm sau desktop icons, trên system
  wallpaper; desktop icons vẫn select/drag/right-click được.
- **Remove Wallpaper**: surface biến mất, desktop picture hiện lại; **Restore Last
  Wallpaper** áp dụng lại video vừa gỡ.
- Chuyển Space, mở Mission Control và một app fullscreen: surface không chen lên trên.
- Relaunch Finder (`killall Finder`), Cmd+Tab và activate/deactivate app: ordering giữ
  nguyên.
- Đổi scaling, mute/volume và loop trong Settings: surface cập nhật theo.
- Cắm/rút display và thay đổi resolution: surface giữ đúng frame.

### Phạm vi Phase 4

- `AppSettings` schema v2, có migration từ schema v1; giữ playback settings, display mode,
  wallpaper state và cấu hình theo display.
- Media được lưu bằng security-scoped bookmark, không chỉ path; bookmark stale được
  refresh khi resolve.
- Persist wallpaper đang active và wallpaper gần nhất; app tự resolve bookmark, validate
  lại video và apply wallpaper khi launch.
- Missing file, mất quyền đọc hoặc bookmark không resolve được hiển thị thành lỗi có
  hành động **Relink…** trong Settings và menu bar.
- Lỗi restore được ghi lại trong settings; app không tự retry vô hạn khi launch mà chờ
  người dùng relink hoặc restore lại.
- Mỗi display được lưu cấu hình theo stable display UUID (`CGDisplayCreateUUIDFromDisplayID`)
  để dùng cho multi-display ở Pha 5.
- Security-scoped resource được giữ trong suốt thời gian media đang dùng và được stop khi
  thay media hoặc terminate.
- Copy Diagnostics có thêm trạng thái persistence, bookmark size và số display
  configuration.

### Kiểm tra persistence thủ công

- Apply một video, thoát app rồi mở lại: wallpaper tự phát lại trên đúng display mode.
- Di chuyển hoặc xóa file video rồi mở lại: Settings hiển thị **Wallpaper video missing**
  cùng nút **Relink…**, không có vòng lặp apply lỗi.
- Chọn lại file qua **Relink…**: wallpaper được apply lại và trạng thái missing biến mất.
- Remove wallpaper, thoát và mở lại: desktop picture vẫn hiện, không tự apply lại.
- Mở app sau khi đã Remove nhưng còn **Restore Last Wallpaper**: restore lại video gần
  nhất từ bookmark đã lưu.
- Relaunch sau khi nâng cấp từ bản schema v1: settings cũ vẫn giữ, schema được ghi thành 2.
- Kiểm tra **Copy Diagnostics** có `active`, `last`, `restoreIssue`, `bookmarkBytes` và
  `displayConfigurations`.

### Phạm vi Phase 5

- `DisplayCoordinator` theo dõi `NSApplication.didChangeScreenParametersNotification`, giữ
  danh sách display theo `CGDirectDisplayID` và UUID ổn định; cập nhật frame/scale khi
  geometry thay đổi.
- Một playback surface cho mỗi display theo cấu hình; display dùng cùng video chia sẻ
  `AVPlayer`, display dùng video khác có player riêng.
- Chế độ **All displays**, **Main display** và **Per display** trong Settings và menu bar.
- Display picker hiển thị tên, kích thước, scale factor, main/built-in/mirrored, video được
  gán và trạng thái surface hiện tại.
- Mỗi display được lưu cấu hình theo persistent UUID; rút display không xóa cấu hình.
  Display đang disconnected hiện trong mục **Saved but disconnected** và có nút **Forget**.
- Khi display quay lại, surface được tạo lại và video đã lưu được áp dụng mà không cần
  thao tác thêm.
- Display mirrored chỉ vẽ một surface trên mirror master; display mirror bị bỏ qua để
  tránh hai cửa sổ chồng nhau.
- Nếu toàn bộ display đã cấu hình bị rút, wallpaper chuyển sang trạng thái
  **Waiting for Display** và tự phục hồi khi display quay lại.
- Copy Diagnostics có thêm display UUID, trạng thái mirrored, cấu hình đã lưu, display
  disconnected và surface hiện tại.

### Kiểm tra multi-display thủ công

- Chọn **All displays**, Apply: mỗi display có một surface, desktop icons và cửa sổ vẫn
  tương tác bình thường.
- Chọn **Per display**, dùng **Use Selected Video** cho từng display với hai video khác
  nhau: mỗi display phát đúng video, tên và trạng thái hiển thị đúng trong picker.
- Rút display ngoài: surface của display đó biến mất, cấu hình vẫn còn trong
  **Saved but disconnected**. Cắm lại: surface và video tự quay lại.
- Rút display duy nhất đã cấu hình trong chế độ per-display: trạng thái chuyển thành
  **Waiting for Display**, Remove Wallpaper vẫn hoạt động.
- Đổi resolution/scale hoặc arrangement: surface cập nhật frame, không có cửa sổ orphan.
- Bật mirrored display: chỉ có một surface trên master; display mirror hiển thị nội dung
  theo master và được đánh dấu **MIRRORED**.
- Chuyển Spaces, Mission Control và app fullscreen: surface không chen lên trên.
- Clear assignment của một display: chỉ display đó mất surface; các display khác giữ
  nguyên video.

### Phạm vi Phase 6

- `PerformanceMonitor` lấy mẫu CPU, memory footprint, GPU utilization (IOAccelerator) và
  dropped frames/stalls từ `AVPlayerItem` access log mỗi 2 giây.
- `ResourcePolicyMonitor` theo dõi fullscreen app, nguồn điện pin/AC, Low Power Mode,
  display sleep, system sleep và thermal pressure. Điều kiện thay đổi sẽ pause/resume các
  surface mà không tạo player mới.
- Pause do resource policy tách khỏi pause thủ công: người dùng vẫn có thể Pause/Play, và
  wallpaper chỉ tự resume khi policy hết điều kiện và người dùng không pause.
- Settings có nhóm **Resource Management** để bật/tắt pause on fullscreen, pause on battery
  và pause in Low Power Mode. Pause do sleep và thermal pressure luôn bật.
- Playback lỗi trên surface được retry tối đa 2 lần với backoff; retry count reset sau 20
  giây phát ổn định. Hết retry mới chuyển sang trạng thái lỗi.
- Thay đổi mute/volume/scaling không tạo player mới; thay đổi loop chỉ rebuild player khi
  thực sự cần. `setPlayer` và `AVPlayerLayer` bỏ qua cập nhật trùng.
- Debug build có **Development Diagnostics** hiển thị metrics trực tiếp, trạng thái policy,
  số player, dropped frames và nút Copy Diagnostics.
- Copy Diagnostics bổ sung resource conditions, pause reasons, CPU/memory/GPU, dropped
  frames, stalls và số surface player.

### Kiểm tra resource management thủ công

- Apply video 1080p rồi 4K, mở **Development Diagnostics**: CPU/GPU/memory và dropped
  frames cập nhật; GPU có thể hiện `unavailable` trên một số máy.
- Bật **Pause when a fullscreen app is active**, mở một app fullscreen: wallpaper pause
  trong tối đa vài giây; thoát fullscreen: wallpaper resume.
- Để máy chạy pin hoặc bật Low Power Mode với tùy chọn tương ứng: wallpaper pause và tự
  resume khi cắm adapter/tắt Low Power Mode.
- Cho display sleep hoặc system sleep rồi wake: playback pause và resume đúng.
- Pause thủ công rồi thay đổi điều kiện policy: wallpaper không tự play lại khi policy hết.
- Đổi mute/volume/scaling: số surface player không tăng và không có player dư thừa.
- Làm file video mất quyền/đọc lỗi khi đang phát: log ghi retry có giới hạn, sau đó surface
  chuyển sang trạng thái lỗi thay vì retry vô hạn.
- **Copy Diagnostics** có các mục `Resource conditions`, `Pause reasons`, `Performance`,
  `droppedFrames` và `stalls`.

### Phạm vi Phase 7

- Settings chia thành ba nhóm native **General**, **Playback** và **Displays** bằng `TabView`,
  dùng control chuẩn của macOS và hỗ trợ keyboard navigation.
- **General** gồm chọn/preview video, apply/remove/restore wallpaper và **Recent Videos**.
- **Playback** gồm loop, mute, volume, scaling (**Aspect fit**, **Aspect fill**,
  **Center crop**) và resource policy; thay đổi áp dụng ngay cho preview và surface.
- Có thể kéo-thả file video vào cửa sổ Settings; overlay hiển thị định dạng được hỗ trợ.
- **Recent Videos** lưu tối đa 8 video gần nhất bằng security-scoped bookmark, cho phép
  preview lại và **Remove** từng item; danh sách cũng có trong menu bar.
- `AppSettings` schema v4 thêm `recentMedia` và migrate tự động từ schema cũ.
- VoiceOver labels cho preview, scaling, display target và recent items; font dùng text
  style để tôn trọng kích thước chữ của hệ thống; lỗi permission/missing file/unsupported
  format có copy hướng dẫn cụ thể.
- Surface vẫn click-through nên khi Settings đóng, desktop icons và cửa sổ không bị chặn.

### Kiểm tra Phase 7 thủ công

- Mở Settings: chuyển giữa General, Playback và Displays bằng chuột và bằng keyboard.
- Kéo một file MP4/MOV vào bất kỳ tab nào: overlay drop hiện ra và video được validate,
  preview tự phát.
- Đổi **Aspect fit**, **Aspect fill**, **Center crop**: preview và wallpaper surface đổi
  cách hiển thị ngay, không tạo thêm player.
- Import vài video rồi mở **Recent Videos**: item mới nhất ở đầu, **Preview** phát lại,
  **Remove** xóa đúng item; thoát/mở lại app danh sách vẫn còn.
- Kéo/xóa file của một recent item rồi bấm **Preview**: lỗi xuất hiện rõ ràng và item vẫn
  có thể Remove.
- Bật VoiceOver: các nút play/pause, scaling, display target, recent preview/remove đều
  đọc được label và trạng thái.
- Đóng Settings, thao tác desktop icons và cửa sổ ứng dụng khác bình thường.

### Phạm vi Phase 8

- **Launch at login** dùng `SMAppService.mainApp` (Login Items API được Apple hỗ trợ),
  có đăng ký/hủy đăng ký, đọc lại trạng thái thực tế và xử lý `requiresApproval` bằng
  nút mở System Settings → General → Login Items.
- Toggle **Launch Wallpaper at login** nằm trong nhóm **Startup & Distribution** ở tab
  General; preference được lưu trong `AppSettings.launchAtLogin`.
- Card **Startup & Distribution** hiển thị chữ ký, team identifier, hardened runtime,
  App Sandbox và việc app có nằm trong `/Applications` hay không.
- Diagnostics có thêm trạng thái launch at login, số security-scoped resource đang giữ
  và thông tin phân phối/chữ ký.
- Release bật hardened runtime, không inject base entitlements và dùng timestamp khi ký.
- Đã xác định entitlements App Sandbox tối thiểu cho file access:
  `app-sandbox`, `files.user-selected.read-only`, `files.bookmarks.app-scope`.
- `Resources/PrivacyInfo.xcprivacy` khai báo required-reason API `UserDefaults`; app không
  có telemetry hoặc crash reporting nên không cần privacy policy.
- Quy trình release Developer ID: build archive, export, notarize + staple app, tạo DMG,
  notarize + staple DMG, verify Gatekeeper; chi tiết trong
  [`DISTRIBUTION.md`](DISTRIBUTION.md).
- DMG có shortcut Applications và file **Uninstall Wallpaper.txt**; hướng dẫn xóa cấu
  hình/login item nằm trong DMG và `Distribution/Uninstall Wallpaper.txt`.

### Kiểm tra Phase 8 thủ công

- Mở Settings → General: bật **Launch Wallpaper at login**, thoát và đăng nhập lại; app
  tự mở và trạng thái trong Settings là **On**.
- Tắt toggle, đăng xuất/đăng nhập lại: app không tự mở; trạng thái là **Off**.
- Nếu macOS trả về **Waiting for approval**, bấm **Open Login Items…** và duyệt app;
  mở lại Settings để thấy trạng thái cập nhật.
- Chạy app từ thư mục ngoài `/Applications`: trạng thái login item có thể là
  **Unavailable**; chuyển app vào Applications rồi thử lại.
- Kiểm tra **Copy Diagnostics** có `Distribution`, `launchAtLogin`,
  `securityScopedResources`, `hardenedRuntime` và `sandbox`.
- Build Release bằng `DEVELOPMENT_TEAM=... ./Scripts/release.sh` trên máy có chứng chỉ
  Developer ID; mở DMG trên máy sạch, kéo app vào Applications và mở không bị Gatekeeper
  chặn.
- Chạy `./Scripts/verify-release.sh Build/Wallpaper.dmg`: staple hợp lệ và Gatekeeper
  chấp nhận.
- Theo hướng dẫn trong DMG để uninstall; kiểm tra app, login item và preference đã được
  xóa.

### Đồng bộ Lock Screen (Màn hình khóa)

- Khi **Set for Lock Screen** bật (mặc định), việc apply video sẽ tự động đồng bộ sang màn hình khóa macOS:
  - Video được inject vào hệ thống native aerials screensaver của macOS (`com.apple.wallpaper/aerials` và `Store/Index.plist`).
  - Screensaver module được cấu hình dùng `WallpaperAerialsExtension` để lock screen phát video native mượt mà.
  - Snapshot ảnh độ phân giải cao được tạo và cập nhật vào cache màn hình khóa `/Library/Caches/Desktop Pictures/<UUID>/lockscreen.png` và system desktop image via `NSWorkspace`.
  - Khi màn hình khóa kích hoạt (`com.apple.sessionagent.screenIsLocked`), surface window tạm dừng playback để tiết kiệm GPU/CPU và nhường chỗ cho lock screen native. Khi mở khóa, surface window tiếp tục phát ngay lập tức.
  - Khi người dùng bấm **Remove Wallpaper** hoặc tắt toggle, lock screen được hoàn trả về mặc định.

### Kiểm tra playback thủ công

Dùng **Choose Video…** hoặc **Preview Fixture** trong Settings, sau đó kiểm tra:

- File lớn (vài trăm MB): import không treo UI; preview phát được sau khi validate.
- File không có audio: preview vẫn phát, nút Mute không gây lỗi.
- File dài: seek/restart hoạt động, thời lượng hiển thị đúng.
- Codec không hỗ trợ: card hiển thị lỗi codec và gợi ý dùng H.264/HEVC.
- Loop bật: video quay vòng không có khoảng đen; Loop tắt: dừng ở cuối và chuyển Paused.
- Thay media liên tiếp: không có player/observer cũ tiếp tục chạy.

### Cấu trúc

```text
WallpaperApp/
├── WallpaperApp.xcodeproj
├── WallpaperApp-Sandbox.entitlements  # entitlements cho nhánh Mac App Store
└── WallpaperApp/
    ├── AppLifecycle/       App entry, AppDelegate, AppModel, trạng thái
    ├── MenuBarFeature/     Menu bar item và menu content
    ├── SettingsFeature/    Settings window, media card, startup card và playback controls
    ├── MediaLibrary/       MediaReference, validation/import, development fixture
    ├── PlaybackEngine/     Playback state, looping engine và preview layer
    ├── WallpaperSurface/   Surface strategy đã xác minh ở Pha 0
    ├── DisplayCoordinator/ Theo dõi NSScreen và thay đổi display
    ├── Persistence/        AppSettings schema, bookmark resolver và wallpaper state
    ├── ResourcePolicy/     Chính sách tài nguyên theo playback settings
    ├── Diagnostics/        Thông tin version/OS/log subsystem
    ├── Support/            OSLog, launch at login và distribution info
    └── Resources/          Fixture video (Debug) và PrivacyInfo.xcprivacy
```

Scripts phân phối: `build-release.sh`, `notarize.sh`, `create-dmg.sh`,
`verify-release.sh`, `release.sh`. Hướng dẫn và quyết định kênh phân phối nằm trong
[`DISTRIBUTION.md`](DISTRIBUTION.md).

### Logging

Subsystem: `com.local.wallpaperapp`. Category: `app`, `settings`, `menu-bar`, `media`,
`playback`, `surface`, `display`, `persistence`, `policy`, `diagnostics`, `startup`,
`distribution`.

Quy ước:

- `notice` cho launch/terminate và hành động người dùng nhìn thấy.
- `info` cho thay đổi trạng thái và cấu hình.
- `debug` cho chi tiết chỉ cần khi phát triển.
- `error` cho lỗi thực sự; không dùng log để thay thế UI lỗi.
- Chỉ dùng `privacy: .public` cho dữ liệu không nhạy cảm. Tên/path file nên để mặc định
  private trừ khi cần chẩn đoán cụ thể.

Xem log trực tiếp:

```bash
./Scripts/logs-app.sh
```

### Fixture video

`WallpaperApp/WallpaperApp/Resources/wallpaper-fixture.mp4` là clip 4 giây, 1280×720,
H.264, có color bar và timecode. Fixture chỉ được bundle trong Debug; cấu hình Release
loại file này khỏi app. Trong Debug, Settings và menu bar có mục **Reveal Development
Fixture**.

## Phase 0 spike

Code nằm trong `WallpaperSpike/`; quyết định kỹ thuật và bảng compatibility nằm trong
[`FEASIBILITY.md`](FEASIBILITY.md).

### Build và chạy spike

```bash
./Scripts/build.sh        # build Debug, in ra đường dẫn .app
./Scripts/run-spike.sh    # build rồi mở app
```

App có cửa sổ điều khiển để chọn video, tạo test pattern, chọn display/window level,
bật/tắt click-through, chạy surface, pause/resume và probe window ordering.

### Self-test tự động

```bash
./Scripts/self-test.sh
```

Kết quả JSON được ghi vào `Build/feasibility-report.json`. Self-test sẽ:

- tạo fixture video 4 giây bằng AVAssetWriter;
- liệt kê display và scale factor;
- thử lần lượt các window level;
- đọc `CGWindowListCopyWindowInfo` để so sánh surface với Finder desktop icons và
  system wallpaper;
- kiểm tra playback và loop bằng `AVPlayerLooper`;
- ghi danh sách manual checks còn phải làm.

### Demo để kiểm tra bằng mắt

```bash
./Scripts/demo.sh belowDesktopIcons 1 25
# tham số: <level> <displayID> <duration giây>
```

Bỏ `displayID` để app tự chọn `NSScreen.main`. Đây là kiểm tra quan trọng nhất cho
desktop-level surface vì screen capture có thể bỏ sót window có level âm.

### Kiểm tra visibility bằng screen capture

```bash
./Scripts/visibility-check.sh 5
```

Script build app, build tool ScreenCaptureKit trong `Tools/display-capture.swift`,
sau đó chụp từng display khi surface đang chạy và in ra tỉ lệ pixel màu.

Lưu ý: trên macOS 26+, screen capture có thể **không** chứa third-party window ở level âm
dù window vẫn hiển thị trên màn hình vật lý. Vì vậy:

- `Scripts/visibility-check.sh` chỉ là công cụ chẩn đoán/regression, không phải nguồn
  quyết định cuối cùng.
- Luôn xác nhận lại bằng `Scripts/demo.sh` trên màn hình thật.

### Kết quả Phase 0

- Public API `NSWindow` đặt ở `desktopIconWindow - 1` hiển thị video **phía sau desktop
  icons** và **phía trên system wallpaper** trên macOS 27 (đã xác nhận bằng mắt).
- `AVPlayerLooper` loop ổn định, playback rate giữ 1.0 và thời gian phát quay vòng.
- Self-test tạo surface và xác nhận ordering/playback trên cả 2 display với scale 2.0× và
  1.0×; visual trên display ngoài vẫn cần xác nhận thủ công.
- Screen capture trên macOS 27 bỏ qua window ở level âm; đây là giới hạn của công cụ
  test, không phải lỗi hiển thị.
- Strategy chính: desktop-level borderless window. Fallback: normal-level click-through
  overlay (chấp nhận che icons) hoặc giới hạn ở màn hình chính; chi tiết trong
  `FEASIBILITY.md`.

## Ngoài phạm vi hiện tại

- Phân phối qua Mac App Store và provisioning profile tương ứng; entitlements sandbox đã
  chuẩn bị nhưng chưa phải kênh phát hành chính.
- Automated soak test dài hạn và đo dropped frames trên phần cứng/1080p/4K thực tế.
- Manual matrix còn lại cho Spaces, Mission Control và một số tổ hợp display/sleep/wake.
- Telemetry/crash reporting và privacy policy tương ứng (hiện app không thu thập dữ liệu).

Xem `PLAN.md` để biết phạm vi các pha tiếp theo và `DISTRIBUTION.md` cho quy trình phát
hành.
