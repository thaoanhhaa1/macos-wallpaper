# SECURITY.md — Mô hình bảo mật & lộ trình Lock Screen XPC

Tài liệu này mô tả mô hình bảo mật của **Wallpaper (macOS)**, các điểm guard hiện có cho
tính năng Lock Screen, mô hình đe dọa (threat model) và thiết kế đề xuất cho kiến trúc
XPC Helper có phân quyền.

## 1. Phiên bản được hỗ trợ

| Phiên bản | macOS | Trạng thái |
| :--- | :--- | :--- |
| 1.1.x | 14.0+ | Được hỗ trợ, nhận bản vá bảo mật (Hiện tại) |
| 1.0.x | 14.0+ | Phiên bản cũ, khuyến nghị nâng cấp lên 1.1.0 |

Chỉ các bản build release từ nhánh chính (`Scripts/release.sh`, Developer ID + notarize)
được coi là bản phát hành hỗ trợ.

## 2. Báo cáo lỗ hổng

- **Không** mở public issue cho lỗ hổng bảo mật.
- Báo cáo riêng cho maintainer của dự án kèm: mô tả, bước tái hiện, mức ảnh hưởng, bản
  build bị ảnh hưởng (sandbox hoặc `SANDBOX=0`).
- Phản hồi trong vòng 7 ngày; bản vá phát hành qua kênh release + notarize thông thường.

## 3. Mô hình bảo mật tổng thể

- **App Sandbox luôn bật** cho Debug và Release (`ENABLE_APP_SANDBOX = YES` trong
  `project.pbxproj`), entitlements tối thiểu:
  `app-sandbox`, `files.user-selected.read-only`, `files.bookmarks.app-scope`.
  Không có quyền network, AppleEvents, camera/mic hay temporary-exception.
- **Không phụ thuộc bên thứ ba** và không có network/telemetry/crash reporting.
- **Hardened Runtime + Developer ID + notarization** cho bản release; `release.sh` chủ
  động từ chối (`exit 1`) build `SANDBOX=0`, `verify-release.sh` từ chối artifact thiếu
  sandbox entitlement hoặc có `get-task-allow`.
- **Bản `SANDBOX=0` chỉ dùng cho phát triển cục bộ**, không bao giờ được phân phối.

## 4. Guard Lock Screen trong bản Sandbox

Các thao tác của Lock Screen đều ghi ra ngoài container và do đó bị App Sandbox chặn.
Toàn bộ feature được vô hiệu hóa tại runtime thay vì để bị lỗi khi chạy:

| Điểm guard | Vị trí | Hành vi |
| :--- | :--- | :--- |
| Kiểm tra entitlement sandbox lúc runtime (`SecTaskCopyValueForEntitlement`) | `Support/DistributionInfo.swift:77-85` | `isSandboxed` được suy ra từ tiến trình đang chạy, không dựa vào build settings |
| `isSupported = !isSandboxed` | `Support/LockScreenController.swift:37-42` | Không đọc trạng thái store khi không hỗ trợ |
| `requireSupport()` gate mọi entry point | `LockScreenController.swift:52, 107, 144, 167-178` | `sync` / `ensureHealthy` / `remove` là no-op có log khi sandbox |
| Sanitize setting khi khởi động | `AppLifecycle/AppModel.swift:81-85` | `syncLockScreen` bị ép về `false`, không tự kích hoạt lại |
| UI ẩn toggle và hiển thị thông báo | `SettingsFeature/WallpaperCard.swift:71-106` | Người dùng không thể bật tính năng trong bản sandbox |

Khi guard đang hoạt động, app **không** thực hiện bất kỳ thao tác nào sau đây:

- Ghi `~/Library/Application Support/com.apple.wallpaper/` (aerials, `entries.json`,
  `Store/Index.plist`).
- Ghi `/Library/Caches/Desktop Pictures/<GeneratedUID>/lockscreen.png` (dùng `lstat`
  kiểm tra loại thư mục + owner, `rename(2)`/`unlink(2)` không theo symlink).
- Ghi `com.apple.screensaver` `moduleDict` qua `CFPreferences`.
- Gửi `SIGTERM` tới `com.apple.wallpaper.agent` (tiến trình của chính người dùng).

Tất cả các thao tác trên chỉ chạy trong bản `SANDBOX=0` không phân phối, với phạm vi
user hiện tại (không đụng cache của user khác) và luôn có backup/rollback
(`lock-screen-backup/`).

## 5. Threat model

### Tài sản (Assets)

1. Thư viện media và bookmark của người dùng trong container app.
2. Cấu hình wallpaper/lock screen của hệ thống (`Index.plist`, `entries.json`).
3. Cache desktop pictures dùng chung (`/Library/Caches/Desktop Pictures`).
4. Quyền riêng tư: tên/đường dẫn tệp media.

### Đối thủ & kịch bản (Adversaries)

| Kịch bản | Ranh giới | Mitigation hiện có |
| :--- | :--- | :--- |
| Video độc hại khai thác lỗi parser AVFoundation | Sandbox container | Sandbox giới hạn ảnh hưởng về container; validate UTType + metadata trước khi đưa vào AVFoundation |
| Local user/app khác lợi dụng thao tác ghi cache (symlink/TOCTOU) | Quyền user | Chỉ thao tác user hiện tại; `lstat` + `rename(2)`/`unlink(2)` không theo symlink; kiểm tra owner `getuid()` |
| App khác tự ý sửa store lock screen | Quyền user | Đây là rủi ro nền tảng macOS (store không được bảo vệ bởi OS); app chỉ ghi trạng thái của chính mình và có backup/rollback |
| Lộ tên/đường dẫn tệp qua log/clipboard | OSLog, pasteboard | Log dùng `privacy: .private` cho path; `DiagnosticsRedactor` băm tên media trong Copy Diagnostics |
| Tấn công network | Không áp dụng | App không có network entitlement và không gọi network API |

### Ngoài phạm vi (Non-goals)

- Root/kernel compromise hoặc lỗi 0-day trong AVFoundation/VideoToolbox.
- Người dùng chủ động chạy app bằng `sudo`.
- Sandbox bypass do lỗi hệ điều hành.

## 6. Lộ trình XPC Helper (dài hạn, chưa triển khai)

Mục tiêu: khôi phục tính năng Lock Screen **trong bản sandbox** mà không phá vỡ mô hình
bảo mật, bằng cách tách các thao tác đặc quyền sang một tiến trình riêng có xác thực.

### 6.1. Kiến trúc đề xuất

- **Privileged Helper Tool** `com.tcs.wallpaper.helper`:
  - Cài đặt qua `SMAppService.daemon` (macOS 13+, thay thế `SMJobBless` đã deprecated).
  - Helper có bundle riêng, Info.plist khai báo `SMAuthorizedClients` ràng buộc code
    signing của app (`identifier "com.tcs.wallpaper" and anchor apple generic and
    certificate leaf[subject.OU] = "<TEAM_ID>"`).
- **XPC protocol cố định**, chỉ gồm các operation đóng gói sẵn, ví dụ:

  ```swift
  @protocol LockScreenHelperProtocol
  - (void)installAsset:(NSDictionary *)validatedAsset
              reply:(void (^)(NSError *_Nullable))reply;
  - (void)removeAsset:(void (^)(NSError *_Nullable))reply;
  - (void)repairState:(void (^)(NSError *_Nullable))reply;
  @end
  ```

  Helper **không bao giờ** nhận đường dẫn tùy ý từ client; mọi đường dẫn đều suy ra từ
  hằng số của helper (asset ID cố định, thư mục chuẩn).

### 6.2. Xác thực và phân quyền

- **Client validation mỗi kết nối**: kiểm tra audit token
  (`NSXPCConnection.auditToken` + `SecCodeCopyGuestWithAttributes`) khớp với
  `SecRequirement` của app; từ chối mọi client khác.
- **Authorization Services**: người dùng xác nhận qua right
  `com.tcs.wallpaper.lockscreen` trước lần cài helper đầu tiên và trước các thao tác
  ghi đè cấu hình hệ thống (`AuthorizationCreate` với prompt).
- **Least privilege, hai tầng nếu cần**:
  - Tầng user agent (không root): ghi aerials/`entries.json`/`Index.plist` trong thư mục
    user — không cần root.
  - Tầng root helper: chỉ ghi `/Library/Caches/Desktop Pictures/<uid>/lockscreen.png`.
    Nếu có thể, cân nhắc sandbox extension (`client` với `temporary-exception` đầy đủ
    audit trail) thay vì root.

### 6.3. An toàn dữ liệu

- Giữ nguyên các biện pháp hiện có trong helper: backup trước khi ghi, atomic
  `rename(2)`/`replaceItemAt`, `lstat` + kiểm owner, không theo symlink.
- Validate đầu vào XPC: giới hạn kích thước/thời lượng video, asset ID và extension cố
  định, loại bỏ tham số tự do.
- Ghi log audit bằng `os_log` với `privacy: .private` cho path, log rõ mã lỗi của từng op.

### 6.4. Vòng đời và rollout

- Feature flag `LockScreenTransport` với hai mode:
  - `inProcess` (hiện trạng): chỉ dùng cho bản `SANDBOX=0` dev.
  - `xpc`: chỉ bật khi helper cài đặt thành công và pass validation; nếu helper lỗi hoặc
    chưa cài, tính năng tắt một cách im lặng + có log.
- Gỡ cài đặt phải: restore backup, hủy đăng ký daemon (`SMAppService`), xóa helper.
- Helper phải có cơ chế handshake phiên bản protocol; app cũ + helper mới (hoặc ngược
  lại) phải fallback về trạng thái tắt, không bao giờ ghi dữ liệu lệch schema.

### 6.5. Tiêu chí nghiệm thu trước khi bật XPC

1. Helper từ chối client không đúng chữ ký (test bằng app giả mạo cùng bundle ID nhưng
   team khác).
2. Helper từ chối message có path tự do, payload quá lớn, hoặc sai schema.
3. Symlink/TOCTOU test trên cache directory vẫn an toàn.
4. Crash/restart của helper không để lại store ở trạng thái hỏng (backup + rollback).
5. Gỡ app/gỡ helper trả hệ thống về trạng thái sạch.
6. `verify-release.sh` mở rộng để kiểm tra chữ ký + entitlement của helper trong DMG.

## 7. Rủi ro tồn dư

- Lock Screen phụ thuộc layout nội bộ của `com.apple.wallpaper` store (không phải API
  công khai); cập nhật macOS có thể làm hỏng tính năng — cần re-test sau mỗi bản macOS.
- Bản `SANDBOX=0` dev vẫn có quyền user đầy đủ; tuyệt đối không phân phối.
- Cho đến khi XPC Helper hoàn thành, người dùng bản release (sandbox) không có Lock
  Screen sync — đây là đánh đổi có chủ đích để giữ mô hình bảo mật.

## 8. Tham chiếu

- `DISTRIBUTION.md` — quy trình build/sign/notarize và chính sách release gate.
- `Scripts/check-release-policy.sh` — script kiểm tra tuân thủ chính sách an toàn khi phát hành.
- `Scripts/verify-release.sh` — gate kiểm chứng artifact (.app và .dmg) trước khi phân phối.
