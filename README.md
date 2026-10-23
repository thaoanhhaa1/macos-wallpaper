# Wallpaper for macOS

Ứng dụng macOS native dùng video làm hình nền động. Repo hiện có hai phần:

- `WallpaperSpike/` — feasibility spike của Pha 0.
- `WallpaperApp/` — ứng dụng thật, hiện hoàn thành Pha 1, Pha 2, Pha 3 và Pha 4.

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

Bundle identifier: `com.local.wallpaperapp`. Signing hiện là ad-hoc
(`CODE_SIGN_IDENTITY = "-"`), chưa bật App Sandbox hoặc hardened runtime; các phần này
thuộc Pha 8.

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
└── WallpaperApp/
    ├── AppLifecycle/       App entry, AppDelegate, AppModel, trạng thái
    ├── MenuBarFeature/     Menu bar item và menu content
    ├── SettingsFeature/    Settings window, media card và playback controls
    ├── MediaLibrary/       MediaReference, validation/import, development fixture
    ├── PlaybackEngine/     Playback state, looping engine và preview layer
    ├── WallpaperSurface/   Surface strategy đã xác minh ở Pha 0
    ├── DisplayCoordinator/ Theo dõi NSScreen và thay đổi display
    ├── Persistence/        AppSettings schema, bookmark resolver và wallpaper state
    ├── ResourcePolicy/     Chính sách tài nguyên theo playback settings
    ├── Diagnostics/        Thông tin version/OS/log subsystem
    ├── Support/            OSLog subsystem và category
    └── Resources/          Fixture video cho debug
```

### Logging

Subsystem: `com.local.wallpaperapp`. Category: `app`, `settings`, `menu-bar`, `media`,
`playback`, `surface`, `display`, `persistence`, `policy`, `diagnostics`.

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

## Chưa nằm trong Phase 0–4

- Launch at login.
- Multi-display configuration UI đầy đủ (Phase 5); Phase 4 mới lưu cấu hình theo display.
- Resource policy (pause on fullscreen/battery/sleep tùy chọn).
- Signing, sandbox, notarization.
- Manual matrix đầy đủ cho Spaces, Mission Control, fullscreen, sleep/wake và hot-plug.

Xem `PLAN.md` để biết phạm vi các pha tiếp theo.
