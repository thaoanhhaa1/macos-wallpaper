# Phân phối Wallpaper cho macOS

Tài liệu này mô tả kênh phân phối của Pha 8: **Developer ID ngoài Mac App Store**,
hardened runtime, notarization và DMG tối giản. Phần đánh giá Mac App Store nằm ở
cuối tài liệu.

## Kênh phân phối đã chọn

- Phiên bản phát hành: **1.1.0 (Build 2)**.
- Phân phối trực tiếp bằng **Developer ID Application** + **notarization**.
- Release bật **Hardened Runtime** và **App Sandbox** (`SANDBOX=1` mặc định); Debug dùng ad-hoc signing để phát triển.
- Entitlements App Sandbox tối thiểu nằm trong
  `WallpaperApp/WallpaperApp-Sandbox.entitlements`.
- Bản release sandbox không thực hiện các thao tác đặc quyền của tính năng Lock Screen
  (ghi ngoài container, đổi screensaver preference, điều khiển `WallpaperAgent`); tính
  năng này cần build không sandbox dành cho phát triển (`SANDBOX=0`). Xem
  [`SECURITY.md`](SECURITY.md) để biết mô hình đe dọa và lộ trình XPC Helper.

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
# 0. Kiểm tra tuân thủ chính sách release
./Scripts/check-release-policy.sh

# 1. Chạy quy trình release đầy đủ
DEVELOPMENT_TEAM=ABCDE12345 ./Scripts/release.sh
```

Script thực hiện:

1. `Scripts/check-release-policy.sh` — xác minh không commit nhầm file build/artifact,
   bắt buộc script build có `SANDBOX=1`, và entitlements kích hoạt sandbox.
2. `Scripts/build-release.sh` — archive cấu hình Release với App Sandbox (`SANDBOX=1`),
   ký bằng Developer ID, bật hardened runtime, thêm timestamp và export app.
3. `Scripts/notarize.sh` — zip app, gửi notarization, chờ kết quả, staple app.
4. `Scripts/create-dmg.sh` — chạy `Scripts/verify-release.sh` trên app trước khi đóng
   gói (từ chối app ad-hoc, thiếu sandbox, còn `get-task-allow` hoặc chứa fixture Debug),
   rồi tạo DMG có app, shortcut Applications và file hướng dẫn uninstall.
5. Notarize và staple DMG.
6. `Scripts/verify-release.sh` — kiểm tra staple, chữ ký Developer ID Application,
   hardened runtime, sandbox entitlement, cấm `get-task-allow`, kiểm tra Gatekeeper
   trên cả `.app` và `.dmg` (mount và quét bundle bên trong).

Artifact cuối cùng: `Build/Wallpaper.dmg`.

### Release Gate CI

GitHub Actions workflow `.github/workflows/release-gate.yml` tự động chạy
`./Scripts/check-release-policy.sh` trên môi trường `macos-latest` mỗi khi push hoặc mở PR
vào nhánh `master` / `main`, ngăn chặn việc phát hành hoặc hợp nhất mã nguồn vi phạm chính
sách bảo mật.

### Biến môi trường

| Biến | Mặc định | Ý nghĩa |
| --- | --- | --- |
| `DEVELOPMENT_TEAM` | bắt buộc | Team ID của Apple Developer |
| `DEVELOPER_ID_APPLICATION` | `Developer ID Application` | Tên identity dùng để ký |
| `NOTARY_PROFILE` | `wallpaper-notary` | Keychain profile của notarytool |
| `SANDBOX` | `1` | Đặt `0` để build không sandbox cho phát triển local |

Build release chuẩn (sandbox):

```bash
DEVELOPMENT_TEAM=ABCDE12345 ./Scripts/release.sh
```

Chỉ dùng build không sandbox để thử tính năng Lock Screen; `Scripts/release.sh` và
`Scripts/verify-release.sh` từ chối artifact này nên không thể phát hành nhầm:

```bash
DEVELOPMENT_TEAM=ABCDE12345 SANDBOX=0 ./Scripts/build-release.sh
```

### Đóng gói DMG để test local (Không cần chứng chỉ Developer ID trả phí)

Nếu chỉ muốn build và đóng gói nhanh thành file `.dmg` để thử nghiệm trên máy cá nhân mà không cần tài khoản Apple Developer trả phí hay Notarization:

```bash
# 1. Build bản debug cục bộ
./Scripts/build-app.sh

# 2. Chuẩn bị staging và đóng gói file DMG
rm -rf Build/DMGStage Build/Wallpaper-Local.dmg
mkdir -p Build/DMGStage
ditto Build/AppDerivedData/Build/Products/Debug/WallpaperApp.app Build/DMGStage/WallpaperApp.app
ln -s /Applications Build/DMGStage/Applications

# 3. Tạo DMG (dùng diskutil trên macOS mới hoặc fallback hdiutil)
if diskutil image create --help &>/dev/null; then
  diskutil image create from --format UDZO --volumeName "Wallpaper" Build/DMGStage Build/Wallpaper-Local.dmg
else
  hdiutil create -volname "Wallpaper" -srcfolder Build/DMGStage -ov -format UDZO Build/Wallpaper-Local.dmg
fi
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
- Entitlement `com.apple.security.files.bookmarks.app-scope` cho phép bookmark còn hiệu lực
  sau khi khởi động lại trong sandbox.

## Đánh giá Mac App Store

Entitlements tối thiểu nằm trong `WallpaperApp/WallpaperApp-Sandbox.entitlements`:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-only</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
```

Các điểm cần đánh giá trước khi chọn Mac App Store:

- **Lock Screen**: đồng bộ màn hình khóa cần ghi vào
  `~/Library/Application Support/com.apple.wallpaper`, đổi screensaver preference và
  điều khiển `WallpaperAgent`; các thao tác này bị App Sandbox chặn. Bản release sandbox
  tự vô hiệu hóa tính năng; muốn giữ tính năng phải tách thành helper/XPC đặc quyền có
  authorization (xem [`SECURITY.md`](SECURITY.md)).
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
   - bản release sandbox: `rm -rf ~/Library/Containers/com.tcs.wallpaper`
   - bản phát triển không sandbox: `defaults delete com.tcs.wallpaper`

## Troubleshooting

- **`No Developer ID Application identity found`**: cài chứng chỉ Developer ID trong
  keychain hoặc kiểm tra `security find-identity -v -p codesigning`.
- **Notarization invalid**: thường do ký thiếu timestamp hoặc còn code chưa ký; chạy
  `codesign --verify --deep --strict --verbose=4` trên app đã export.
- **Gatekeeper vẫn chặn**: kiểm tra `xcrun stapler validate` trên đúng artifact đã
  staple; DMG và app nên được staple riêng.
- **Login item unavailable khi chạy từ Build**: chuyển app vào `/Applications` và ký
  bằng Developer ID rồi thử lại.
