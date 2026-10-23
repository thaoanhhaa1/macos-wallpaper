# Phân phối Wallpaper cho macOS

Tài liệu này mô tả kênh phân phối của Pha 8: **Developer ID ngoài Mac App Store**,
hardened runtime, notarization và DMG tối giản. Phần đánh giá Mac App Store nằm ở
cuối tài liệu.

## Kênh phân phối đã chọn

- Phân phối trực tiếp bằng **Developer ID Application** + **notarization**.
- Release bật **Hardened Runtime**; Debug vẫn dùng ad-hoc signing để phát triển.
- App Sandbox tắt cho bản Developer ID vì không bắt buộc ngoài App Store.
- Entitlements cho App Sandbox đã được chuẩn bị sẵn cho nhánh Mac App Store.

## Yêu cầu

- Apple Developer Program còn hiệu lực.
- Chứng chỉ **Developer ID Application** đã cài trong keychain.
- Xcode command line tools và `notarytool`.
- Một keychain profile cho notarytool:

```bash
xcrun notarytool store-credentials wallpaper-notary \
  --apple-id "you@example.com" \
  --team-id "ABCDE12345" \
  --password "app-specific-password"
```

Có thể đổi tên profile bằng biến môi trường `NOTARY_PROFILE`.

## Quy trình release

```bash
DEVELOPMENT_TEAM=ABCDE12345 ./Scripts/release.sh
```

Script thực hiện:

1. `Scripts/build-release.sh` — archive cấu hình Release, ký bằng Developer ID,
   bật hardened runtime, thêm timestamp và export app.
2. `Scripts/notarize.sh` — zip app, gửi notarization, chờ kết quả, staple app.
3. `Scripts/create-dmg.sh` — tạo DMG có app, shortcut Applications và file hướng dẫn
   uninstall.
4. Notarize và staple DMG.
5. `Scripts/verify-release.sh` — kiểm tra staple, chữ ký, hardened runtime và
   Gatekeeper.

Artifact cuối cùng: `Build/Wallpaper.dmg`.

### Biến môi trường

| Biến | Mặc định | Ý nghĩa |
| --- | --- | --- |
| `DEVELOPMENT_TEAM` | bắt buộc | Team ID của Apple Developer |
| `DEVELOPER_ID_APPLICATION` | `Developer ID Application` | Tên identity dùng để ký |
| `NOTARY_PROFILE` | `wallpaper-notary` | Keychain profile của notarytool |
| `SANDBOX` | `0` | Đặt `1` để build thử bản có App Sandbox |

Build release có sandbox để đánh giá:

```bash
DEVELOPMENT_TEAM=ABCDE12345 SANDBOX=1 ./Scripts/build-release.sh
```

## Kiểm tra thủ công sau release

```bash
# Chữ ký và hardened runtime
codesign --verify --deep --strict --verbose=2 Build/ReleaseExport/WallpaperApp.app
codesign -d --verbose=4 Build/ReleaseExport/WallpaperApp.app

# Notarization ticket
xcrun stapler validate Build/Wallpaper.dmg
xcrun stapler validate Build/ReleaseExport/WallpaperApp.app

# Gatekeeper
spctl --assess --type install --verbose=4 Build/Wallpaper.dmg
spctl --assess --type execute --verbose=4 Build/ReleaseExport/WallpaperApp.app

# Hoặc chạy toàn bộ
./Scripts/verify-release.sh Build/ReleaseExport/WallpaperApp.app Build/Wallpaper.dmg
```

Kiểm tra trên máy sạch (hoặc tài khoản macOS mới):

- Mở DMG, kéo app vào Applications, mở app không bị Gatekeeper chặn.
- Bật **Launch Wallpaper at login**, đăng xuất/đăng nhập lại: app tự mở.
- Nếu macOS yêu cầu duyệt, **Open Login Items…** đưa người dùng tới đúng màn hình
  System Settings.
- Chạy app từ ngoài `/Applications` (ví dụ từ thư mục Build): trạng thái login item
  có thể là **Unavailable**; đây là hành vi của `SMAppService`.

## Launch at login

- Dùng `SMAppService.mainApp.register()` / `unregister()`; không tạo helper app riêng
  và không dùng API deprecated `SMLoginItemSetEnabled`.
- Trạng thái được đọc lại từ hệ thống mỗi lần mở Settings, nên thay đổi trong
  System Settings được phản ánh đúng.
- `requiresApproval` hiển thị cảnh báo và nút mở Login Items.
- Preference được lưu trong `AppSettings.launchAtLogin`. Nếu lần đăng ký lúc launch
  thất bại, preference được hạ về `false` để tránh lặp lỗi vô hạn.

## Security-scoped resource lifecycle

- Bookmark được tạo với `.withSecurityScope` và quyền đọc-only cho file người dùng chọn.
- Resource chỉ được giữ khi media còn được preview hoặc đang dùng cho surface; khi thay
  media hoặc terminate, `stopAccessingSecurityScopedResource()` được gọi.
- Diagnostics hiển thị `securityScopedResources` để kiểm tra không có resource bị giữ
  ngoài ý muốn.
- Khi chuyển sang bản sandbox, cần entitlement `com.apple.security.files.bookmarks.app-scope`
  để bookmark còn hiệu lực sau khi khởi động lại.

## Đánh giá Mac App Store

Entitlements tối thiểu nằm trong `WallpaperApp/WallpaperApp-Sandbox.entitlements`:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-only</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
```

Các điểm cần đánh giá trước khi chọn Mac App Store:

- **Cửa sổ desktop-level**: app dùng `NSWindow` công khai ở level
  `desktopIconWindow − 1`. Cần kiểm tra lại sau mỗi bản macOS lớn vì thứ tự window
  và desktop icons là hành vi của hệ thống, không phải API hợp đồng.
- **Spaces, Mission Control, fullscreen, mirrored displays**: phải chạy lại ma trận
  kiểm tra thủ công trên bản sandbox; sandbox không chặn tạo window nhưng có thể ảnh
  hưởng tới quyền truy cập file và login item.
- **Login item**: `SMAppService.mainApp` được hỗ trợ trong sandbox nhưng người dùng vẫn
  phải duyệt trong System Settings.
- **LSUIElement**: app là menu bar utility; cần giải thích rõ trong App Review notes.
- **Không dùng private API** để hạ window xuống dưới desktop icons.
- **Onboarding/permission copy**: App Store review cần lý do rõ ràng cho quyền đọc file
  do người dùng chọn; app chỉ đọc file media.
- **Distribution method**: script hiện tại chỉ hỗ trợ `developer-id`. Nếu chuyển sang
  App Store, cần `method=app-store`, provisioning profile và cấu hình team tương ứng.

## Privacy

- App không có telemetry, analytics hay crash reporting.
- Không có dữ liệu nào được gửi ra ngoài máy.
- `Resources/PrivacyInfo.xcprivacy` chỉ khai báo required-reason API `UserDefaults`
  (`CA92.1`) dùng cho cấu hình cục bộ.
- Vì không thu thập dữ liệu, không cần privacy policy URL. Nếu sau này thêm telemetry
  hoặc crash reporting, phải bổ sung privacy policy, privacy manifest và mục
  **Privacy** trong App Store Connect trước khi phát hành.

## Uninstall

Hướng dẫn có trong DMG và trong `Distribution/Uninstall Wallpaper.txt`:

1. Thoát app từ menu bar.
2. Xóa `WallpaperApp.app` khỏi Applications.
3. Xóa login item trong System Settings → General → Login Items nếu còn.
4. Tùy chọn xóa cấu hình:
   - bản không sandbox: `defaults delete com.local.wallpaperapp`
   - bản sandbox: `rm -rf ~/Library/Containers/com.local.wallpaperapp`

## Troubleshooting

- **`No Developer ID Application identity found`**: cài chứng chỉ Developer ID trong
  keychain hoặc kiểm tra `security find-identity -v -p codesigning`.
- **Notarization invalid**: thường do ký thiếu timestamp hoặc còn code chưa ký; chạy
  `codesign --verify --deep --strict --verbose=4` trên app đã export.
- **Gatekeeper vẫn chặn**: kiểm tra `xcrun stapler validate` trên đúng artifact đã
  staple; DMG và app nên được staple riêng.
- **Login item unavailable khi chạy từ Build**: chuyển app vào `/Applications` và ký
  bằng Developer ID rồi thử lại.
