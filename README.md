# Wallpaper Spike (Phase 0)

Spike xác minh feasibility cho ứng dụng dùng video làm wallpaper trên macOS. Code nằm trong
`WallpaperSpike/`; quyết định kỹ thuật và bảng compatibility nằm trong
[`FEASIBILITY.md`](FEASIBILITY.md).

## Yêu cầu

- macOS 14 trở lên (đã chạy thực tế trên macOS 27.0, arm64).
- Xcode 27 / Swift 6 toolchain.
- Terminal cần quyền **Screen Recording** nếu chạy `Scripts/visibility-check.sh`.

## Build và chạy app

```bash
./Scripts/build.sh        # build Debug, in ra đường dẫn .app
./Scripts/run-spike.sh    # build rồi mở app
```

App có cửa sổ điều khiển để chọn video, tạo test pattern, chọn display/window level,
bật/tắt click-through, chạy surface, pause/resume và probe window ordering.

## Self-test tự động

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

## Demo để kiểm tra bằng mắt

```bash
./Scripts/demo.sh belowDesktopIcons 1 25
# tham số: <level> <displayID> <duration giây>
```

Bỏ `displayID` để app tự chọn `NSScreen.main`. Đây là kiểm tra quan trọng nhất cho
desktop-level surface vì screen capture có thể bỏ sót window có level âm.

## Kiểm tra visibility bằng screen capture

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

## Cấu trúc

```text
WallpaperSpike/
├── WallpaperSpike.xcodeproj
└── WallpaperSpike/
    ├── App/          App lifecycle, chế độ --self-test và --demo
    ├── Model/        SpikeConfiguration, SpikeModel
    ├── Surface/      WallpaperSurfaceWindow/Controller, AVPlayerLayer, playback
    ├── Media/        Test video fixture generator
    ├── Diagnostics/  DisplayProbe, WindowProbe, self-test, report
    ├── UI/           SwiftUI control window
    └── Support/      OSLog subsystem
Scripts/
├── build.sh
├── run-spike.sh
├── self-test.sh
├── demo.sh
└── visibility-check.sh
Tools/
└── display-capture.swift
```

## Kết quả Phase 0

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

## Chưa nằm trong Phase 0

- Persistence, security-scoped bookmark, launch at login.
- Multi-display configuration UI đầy đủ.
- Resource policy (pause on fullscreen/battery/sleep tùy chọn).
- Signing, sandbox, notarization.
- Manual matrix đầy đủ cho Spaces, Mission Control, fullscreen, sleep/wake và hot-plug.

Xem `PLAN.md` để biết phạm vi các pha tiếp theo.
