# Changelog

Mọi thay đổi đáng chú ý của dự án **Wallpaper for macOS** sẽ được ghi lại trong tệp này.
Định dạng dựa trên [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) và tuân thủ [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-10-27

### Tăng cường bảo mật (Security Hardening)
- **App Sandbox kích hoạt mặc định**: Đặt `SANDBOX=1` làm giá trị mặc định cho mọi script build và packaging (`Scripts/build-app.sh`, `Scripts/build-release.sh`, `Scripts/release.sh`). Bản release bắt buộc phải có entitlement `com.apple.security.app-sandbox`.
- **Chính sách phát hành & Release Policy Gate**:
  - Thêm script `Scripts/check-release-policy.sh` tự động kiểm tra: cấm commit file nhị phân vào git, cấm phát hành bản không sandbox, bắt buộc sandbox entitlement, từ chối `get-task-allow`.
  - Thêm GitHub Actions workflow `.github/workflows/release-gate.yml` chạy kiểm tra chính sách phát hành trên mỗi commit / PR vào nhánh chính.
- **Xác thực phát hành mở rộng (`verify-release.sh`)**:
  - Kiểm tra toàn diện file `.dmg`: tự động mount, tìm và kiểm tra gói `.app` bên trong trước khi phân phối.
  - Kiểm tra chữ ký hợp lệ `Developer ID Application`, cờ `flags=...runtime` (Hardened Runtime), và không chứa các tệp debug (`*.debug.dylib`, `__preview.dylib`, `wallpaper-fixture.mp4`).
- **Xác thực định dạng & kích thước Media (`MediaContentType`)**:
  - Kiểm tra UTType hợp lệ (`.mpeg4Movie`, `.quickTimeMovie`).
  - Kiểm tra chữ ký cấu trúc container (magic bytes / top-level box types: `ftyp`, `moov`, `mdat`, `wide`, `free`, `skip`).
  - Giới hạn kích thước tệp video tối đa 20 GB để ngăn ngừa tấn công tràn bộ nhớ/tài nguyên.
- **Bảo vệ quyền riêng tư chẩn đoán (`DiagnosticsRedactor`)**:
  - Thêm module `DiagnosticsRedactor` tự động ẩn/làm mờ (redact) tên tệp video và đường dẫn tệp riêng tư trong bản sao chép Diagnostics.
  - Chuyển đổi toàn bộ log `OSLog` liên quan đến đường dẫn và tên tệp của người dùng sang chế độ `privacy: .private`.
- **Cơ chế an toàn cho Lock Screen**:
  - Nhận biết môi trường App Sandbox tại runtime (`isLockScreenSyncAvailable`); ẩn toggle và hiển thị nhãn trạng thái khi chạy trong sandbox, ngăn ngừa lỗi vi phạm sandbox.
  - Tự động sao lưu `Index.plist` và screensaver preferences (`com.apple.screensaver` `moduleDict`) vào `~/Library/Application Support/com.tcs.wallpaper/lock-screen-backup` trước khi sửa đổi, rollback an toàn khi gỡ wallpaper.
  - Thay thế toàn bộ việc gọi lệnh shell (`/usr/bin/defaults`, `/usr/bin/killall`) bằng API CoreFoundation `CFPreferences` và `NSRunningApplication` + `kill(SIGTERM)`.
- **Củng cố Security-Scoped Bookmarks**:
  - Loại bỏ hoàn toàn cơ chế fallback sang bookmark thường không an toàn ngoài sandbox.
  - Tự động phát hiện và làm mới bookmark cũ (`needsUpgrade`, `wasStale`).

### Thay đổi cấu hình & Tài liệu
- Nâng `MARKETING_VERSION` lên `1.1.0` và `CURRENT_PROJECT_VERSION` lên `2` trong `WallpaperApp.xcodeproj`.
- Thêm `SECURITY.md` mô tả chi tiết mô hình bảo mật, threat model và lộ trình XPC Helper có phân quyền.
- Cập nhật tài liệu phân phối `DISTRIBUTION.md`, `README.md`, và hướng dẫn gỡ cài đặt `Distribution/Uninstall Wallpaper.txt`.

---

## [1.0.0] - 2026-10-24

### Tính năng ban đầu (MVP)
- **Hình nền động Native**: Phát video mượt mà (H.264, HEVC, MP4, MOV) phía dưới desktop icons thông qua cửa sổ `NSWindow` desktop-level chuyên biệt.
- **Looping & Playback Engine**: Tích hợp `AVQueuePlayer` + `AVPlayerLooper`, hỗ trợ tùy chỉnh âm lượng, bật/tắt tiếng (mute), loop liên tục và các chế độ co giãn (`Aspect fit`, `Aspect fill`, `Center crop`).
- **Hỗ trợ đa màn hình (Multi-Display)**:
  - Chế độ **All displays**, **Main display** và **Per display** gán video riêng cho từng màn hình.
  - Ghi nhớ cấu hình màn hình theo UUID ổn định (`CGDisplayCreateUUIDFromDisplayID`); tự phục hồi surface khi cắm lại màn hình đã ngắt kết nối.
- **Quản lý tài nguyên thông minh (Resource Policy)**:
  - Tự động tạm dừng phát khi có ứng dụng fullscreen hoạt động.
  - Tự động tạm dừng khi dùng pin hoặc bật chế độ Tiết kiệm pin (Low Power Mode).
  - Tự động tạm dừng khi màn hình tắt/máy đi vào chế độ Sleep và phục hồi khi Wake.
- **Lưu trữ & Khôi phục (Persistence)**:
  - Lưu trạng thái video bằng Security-Scoped Bookmarks.
  - Tự động phục hồi hình nền sau khi khởi động lại ứng dụng.
  - Xử lý mất file / mất quyền truy cập và cung cấp giao diện **Relink…**.
- **Khởi động cùng macOS**: Tích hợp `SMAppService.mainApp` theo chuẩn hiện đại của Apple trong Settings.
- **Menu Bar Utility**: App chạy dạng thanh menu (`LSUIElement = YES`), điều khiển nhanh trạng thái phát, âm lượng, danh sách Recent Videos và truy cập Settings.
- **Quy trình phân phối Developer ID**: Script đóng gói Release, hardened runtime, notarization tự động qua `notarytool`, và tạo tệp `.dmg`.
