# Wallpaper for macOS

Ứng dụng macOS native dùng video làm hình nền động. Repo hiện có hai phần:

- `WallpaperSpike/` — feasibility spike của Pha 0.
- `WallpaperApp/` — skeleton ứng dụng thật của Pha 1.

Quyết định kỹ thuật và bảng compatibility nằm trong [`FEASIBILITY.md`](FEASIBILITY.md);
phạm vi các pha tiếp theo nằm trong [`PLAN.md`](PLAN.md).

## Yêu cầu

- macOS 14 trở lên (đã chạy thực tế trên macOS 27.0, arm64).
- Xcode 27 / Swift 6 toolchain.
- Terminal cần quyền **Screen Recording** nếu chạy `Scripts/visibility-check.sh`.

## Ứng dụng Pha 1

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

### Phạm vi skeleton

- Menu bar shell với trạng thái `No Wallpaper`, Play/Pause/Mute (disabled), Settings,
  About và Quit.
- Settings window với empty state, danh sách display hiện tại, surface strategy và
  thông tin chẩn đoán.
- App lifecycle dùng SwiftUI `App` + `AppDelegate`/AppKit integration.
- Module/folder structure theo kiến trúc trong `PLAN.md`.
- `OSLog` subsystem và quy ước log.
- Fixture video nhỏ cho development/test.

Chưa nằm trong Pha 1: import video, preview, playback, apply/remove wallpaper,
persistence UI, multi-display configuration, launch at login.

### Cấu trúc

```text
WallpaperApp/
├── WallpaperApp.xcodeproj
└── WallpaperApp/
    ├── AppLifecycle/       App entry, AppDelegate, AppModel, trạng thái
    ├── MenuBarFeature/     Menu bar item và menu content
    ├── SettingsFeature/    Settings window và empty state
    ├── MediaLibrary/       MediaReference, development fixture
    ├── PlaybackEngine/     PlaybackState
    ├── WallpaperSurface/   Surface strategy đã xác minh ở Pha 0
    ├── DisplayCoordinator/ Theo dõi NSScreen và thay đổi display
    ├── Persistence/        AppSettings schema và SettingsStore
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

## Chưa nằm trong Phase 0/1

- Import/validation video và preview.
- Playback engine và apply/remove wallpaper.
- Persistence, security-scoped bookmark, launch at login.
- Multi-display configuration UI đầy đủ.
- Resource policy (pause on fullscreen/battery/sleep tùy chọn).
- Signing, sandbox, notarization.
- Manual matrix đầy đủ cho Spaces, Mission Control, fullscreen, sleep/wake và hot-plug.

Xem `PLAN.md` để biết phạm vi các pha tiếp theo.
