# Kế hoạch phát triển ứng dụng macOS dùng video làm wallpaper

## 1. Tóm tắt mục tiêu

Xây dựng một ứng dụng macOS native cho phép người dùng chọn video và phát video làm hình nền động trên một hoặc nhiều màn hình. Ứng dụng cần hoạt động ổn định trong thời gian dài, ít tiêu thụ CPU/GPU, không cản trở desktop icons và các cửa sổ khác, đồng thời hỗ trợ tự khởi động, tạm dừng khi cần và khôi phục trạng thái sau khi đăng nhập lại.

### Mục tiêu sản phẩm

- Chọn video từ Finder hoặc kéo-thả vào ứng dụng.
- Preview video trước khi áp dụng.
- Đặt video làm wallpaper cho tất cả màn hình hoặc từng màn hình riêng.
- Hỗ trợ loop, mute, âm lượng và tùy chọn crop/fit.
- Điều khiển phát lại từ menu bar và cửa sổ cấu hình.
- Tự khởi động cùng macOS nếu người dùng bật tùy chọn.
- Tự khôi phục wallpaper sau khi app được mở lại.
- Xử lý video không hợp lệ, mất file, màn hình cắm/rút và sleep/wake.
- Gói ứng dụng có thể phân phối ngoài App Store hoặc qua Mac App Store tùy quyết định phát hành.

### Ngoài phạm vi MVP

- Đồng bộ thư viện video giữa nhiều máy.
- Chỉnh sửa video, filter hoặc transcoding chuyên sâu.
- Audio visualization phức tạp.
- Hệ thống subscription hoặc marketplace nội dung.
- Hỗ trợ Windows/Linux.

## 2. Quyết định kỹ thuật ban đầu

### Stack đề xuất

- Ngôn ngữ: Swift.
- UI: SwiftUI cho cửa sổ cấu hình và menu bar; AppKit dùng cho các API desktop-level.
- Playback: AVFoundation, ưu tiên `AVPlayer` và `AVPlayerLayer` hoặc renderer tương đương phù hợp với cách đặt view phía sau desktop icons.
- Quản lý trạng thái: Swift Observation hoặc `ObservableObject`, tùy deployment target.
- Lưu cấu hình: `UserDefaults` cho thiết lập nhỏ; bookmark bảo mật hoặc Security-Scoped Bookmark cho file ngoài sandbox.
- Tự khởi động: `SMAppService` với Login Item nếu deployment target hỗ trợ.
- Logging: `OSLog` với subsystem riêng.
- Kiểm thử: XCTest, XCUITest và các bài test hiệu năng có số liệu định lượng.
- Quản lý dependency: hạn chế dependency ngoài; ưu tiên framework hệ thống.

### Deployment target

Chọn deployment target sau khi chốt các API cần dùng. Mốc đề xuất là macOS 14 trở lên để có API hiện đại và giảm số nhánh tương thích. Nếu cần hỗ trợ hệ điều hành cũ hơn, phải tạo compatibility layer cho startup item, observation và các API display/session.

### Lưu ý quan trọng về wallpaper trên macOS

macOS không cung cấp một API công khai đơn giản để đặt một video trực tiếp làm Desktop wallpaper như ảnh tĩnh. Cần xác minh sớm phương án hiển thị thực tế:

1. Tạo một borderless, non-activating window ở desktop-level phù hợp, đặt dưới cửa sổ ứng dụng nhưng phía trên wallpaper mặc định.
2. Gắn window vào từng `NSScreen`, cho phép desktop icons vẫn hiển thị phía trên nếu `windowLevel`, collection behavior và thứ tự cửa sổ được cấu hình đúng.
3. Khi cần, sử dụng một lớp AppKit riêng để tương tác với desktop window ordering; không phụ thuộc vào private API hoặc thao tác phá vỡ System Integrity Protection.
4. Xác minh behavior trên các phiên bản macOS mục tiêu, Spaces, Mission Control, fullscreen app, nhiều màn hình và các chế độ desktop khác.

Nếu không thể đạt trải nghiệm “phía sau desktop icons” bằng API công khai, cần ghi rõ fallback trong sản phẩm: video được hiển thị như một desktop overlay có thể ẩn/tạm dừng, hoặc chỉ hỗ trợ màn hình chính. Đây là spike bắt buộc trước khi đầu tư toàn bộ UI.

## 3. Kiến trúc tổng thể

Tách ứng dụng thành các module có trách nhiệm rõ ràng:

```text
WallpaperApp
├── AppLifecycle
├── SettingsFeature
├── MediaLibrary
├── PlaybackEngine
├── WallpaperSurface
├── DisplayCoordinator
├── Persistence
├── ResourcePolicy
├── MenuBarFeature
└── Diagnostics
```

### Thành phần chính

#### `AppLifecycle`

- Khởi tạo app, menu bar và cửa sổ settings.
- Restore state sau khi app launch.
- Theo dõi app active/inactive, login, sleep/wake.
- Đảm bảo cleanup player/window khi app terminate.

#### `MediaLibrary`

- Import URL hoặc file reference.
- Kiểm tra file tồn tại và quyền đọc.
- Đọc metadata: duration, kích thước, codec, frame rate, audio track.
- Xác định định dạng được hỗ trợ.
- Quản lý danh sách video gần đây và video đang dùng.

#### `PlaybackEngine`

- Tạo và quản lý player cho từng wallpaper surface.
- Loop không tạo memory leak hoặc tích lũy observer.
- Hỗ trợ play, pause, seek, mute và volume.
- Báo cáo trạng thái loading, ready, playing, paused, failed.
- Áp dụng chính sách giảm tài nguyên khi app không cần phát.

#### `WallpaperSurface`

- Tạo borderless window/view cho từng màn hình.
- Thiết lập frame, level, collection behavior và mouse interaction.
- Không chiếm focus bàn phím.
- Hỗ trợ cập nhật geometry khi resolution/scale factor thay đổi.
- Đảm bảo không để surface nổi trên cửa sổ người dùng.

#### `DisplayCoordinator`

- Theo dõi `NSScreen.screens` và notification liên quan.
- Ánh xạ cấu hình theo display identifier ổn định nhất có thể.
- Áp dụng video cho tất cả màn hình hoặc từng màn hình.
- Tạo/xóa surface khi cắm/rút màn hình.
- Xử lý thay đổi arrangement, resolution, scaling và Spaces.

#### `Persistence`

- Lưu URL bookmark, không chỉ lưu path string.
- Lưu thiết lập playback và display mapping.
- Version hóa schema để nâng cấp dữ liệu sau này.
- Xử lý bookmark stale và yêu cầu người dùng chọn lại file.

#### `ResourcePolicy`

- Quyết định pause khi chạy fullscreen app hoặc khi pin yếu nếu cần.
- Giới hạn số player và mức chất lượng phù hợp.
- Theo dõi memory footprint, dropped frames và playback failure.
- Cho phép người dùng chọn chế độ tiết kiệm tài nguyên.

## 4. Phạm vi MVP

MVP nên tập trung vào một luồng hoàn chỉnh, ít tùy chọn nhưng đủ dùng:

1. Người dùng mở app.
2. Chọn một file video hợp lệ bằng open panel.
3. Xem preview.
4. Bấm “Apply as Wallpaper”.
5. App tạo surface trên màn hình chính và phát video theo loop.
6. Người dùng pause/play/mute từ menu bar.
7. App lưu bookmark và khôi phục video ở lần mở sau.
8. Người dùng có thể bật/tắt launch at login.

### Tiêu chí chấp nhận MVP

- Video phát liên tục tối thiểu 30 phút mà không tăng memory bất thường.
- Loop không tạo khoảng đen rõ rệt hoặc làm player dừng.
- Cửa sổ ứng dụng khác vẫn nhận focus và input bình thường.
- Desktop icons vẫn sử dụng được nếu phương án surface hỗ trợ yêu cầu này.
- App không crash khi file bị xóa hoặc mất quyền đọc.
- Khởi động lại app khôi phục được cấu hình hợp lệ.
- Pause/resume sau sleep/wake không làm treo player.
- Có thông báo lỗi có thể hành động khi codec không hỗ trợ.

## 5. Lộ trình triển khai theo pha

### Pha 0: Xác minh feasibility

**Mục tiêu:** giảm rủi ro lớn nhất trước khi xây UI và persistence.

- Tạo project macOS tối giản bằng SwiftUI/AppKit.
- Hiển thị một video test bằng AVFoundation.
- Thử đặt borderless window ở desktop-level trên một màn hình.
- Kiểm tra desktop icons, Finder context menu, click-through và focus.
- Kiểm tra Spaces, Mission Control, fullscreen app và sleep/wake.
- Kiểm tra nhiều màn hình với scale factor khác nhau.
- Ghi lại giới hạn của API công khai và quyết định surface strategy.

**Output:** spike code, bảng compatibility, quyết định kiến trúc và tiêu chí fallback.

### Pha 1: Skeleton ứng dụng

- Tạo Xcode project, bundle identifier và cấu hình signing cơ bản.
- Dựng app lifecycle với SwiftUI App và AppKit integration.
- Tạo menu bar item, settings window và trạng thái rỗng.
- Thiết lập module/folder structure.
- Thêm `OSLog` subsystem và quy ước log.
- Tạo fixture video nhỏ cho development/test.

**Output:** app chạy được, có settings window và menu bar shell.

### Pha 2: Import và playback engine

- Xây open panel lọc các loại video dự kiến hỗ trợ.
- Tạo media validation bằng `AVAsset` async loading.
- Hiển thị metadata và lỗi theo từng trạng thái.
- Implement player lifecycle, loop và cleanup observer.
- Implement play/pause, seek tùy chọn, mute và volume.
- Bổ sung preview view trong settings.
- Test file lớn, file không có audio, file dài và codec không hỗ trợ.

**Output:** một video có thể import, preview và phát ổn định trong cửa sổ app.

### Pha 3: Wallpaper surface

- Implement window controller cho borderless desktop surface.
- Tách logic rendering khỏi logic playback để dễ test.
- Thiết lập sizing theo `NSScreen.visibleFrame` hoặc frame phù hợp với strategy đã xác minh.
- Cấu hình window collection behavior cho Spaces.
- Chặn mouse/keyboard interaction nếu surface không cần tương tác.
- Xác minh thứ tự hiển thị sau Finder relaunch và khi app activate/deactivate.
- Thêm nút Apply, Remove/Disable và Restore Last Wallpaper.

**Output:** video được áp dụng thành wallpaper theo strategy đã chọn.

### Pha 4: Persistence và khôi phục

- Lưu security-scoped bookmark cho video ngoài container.
- Lưu cấu hình global và cấu hình theo display.
- Version hóa model settings.
- Restore bookmark khi launch và xử lý bookmark stale.
- Hiển thị trạng thái “missing file” cùng hành động Relink.
- Đảm bảo app không tự apply state hỏng vô hạn khi startup.

**Output:** app khởi động lại vẫn khôi phục được wallpaper hợp lệ.

### Pha 5: Multi-display và display lifecycle

- Theo dõi thêm/bớt màn hình và thay đổi geometry.
- Tạo một playback surface cho mỗi màn hình theo cấu hình.
- Cho phép chế độ: tất cả màn hình, màn hình chính, từng màn hình.
- Xây display picker hiển thị tên, kích thước và trạng thái.
- Xử lý màn hình disconnected mà không mất cấu hình.
- Quy định hành vi khi màn hình quay lại.
- Kiểm tra mirrored display và nhiều Spaces.

**Output:** multi-display behavior có thể dự đoán và khôi phục được.

### Pha 6: Resource management và trải nghiệm dùng lâu dài

- Đo CPU, GPU, memory và dropped frames trên video 1080p/4K.
- Pause hoặc giảm hoạt động khi fullscreen app theo tùy chọn.
- Pause khi display sleep, resume khi wake.
- Thêm lựa chọn “pause on battery” hoặc “low power mode” nếu phù hợp.
- Tránh tạo player dư thừa khi thay đổi settings.
- Xử lý thermal pressure và playback errors có retry giới hạn.
- Bổ sung diagnostics view đơn giản cho build development.

**Output:** behavior ổn định khi chạy cả ngày và không gây tải không cần thiết.

### Pha 7: Settings, accessibility và polish

- Hoàn thiện layout settings theo các nhóm: General, Playback, Displays.
- Dùng control native và keyboard navigation.
- Bổ sung VoiceOver labels, Dynamic Type phù hợp và trạng thái lỗi rõ ràng.
- Thêm drag-and-drop video.
- Thêm Recent Videos và Remove Recent Item.
- Thêm preview crop/fit: aspect fit, aspect fill và center crop.
- Xác định copy cho permission, missing file và unsupported format.
- Bảo đảm UI không chặn thao tác desktop khi settings đóng.

**Output:** trải nghiệm MVP hoàn chỉnh, accessible và dễ hiểu.

### Pha 8: Startup, permissions, signing và phân phối

- Implement launch at login bằng API được Apple hỗ trợ.
- Xác định sandbox entitlements cần thiết cho file access.
- Kiểm tra security-scoped resource lifecycle.
- Thiết lập Developer ID signing và hardened runtime nếu phân phối ngoài App Store.
- Chuẩn bị notarization workflow.
- Nếu chọn Mac App Store, đánh giá sandbox/window/display restrictions sớm.
- Tạo DMG hoặc installer tối giản, kèm uninstall instructions.
- Bổ sung privacy policy nếu telemetry hoặc crash reporting được thêm.

**Output:** bản release có thể cài đặt, ký và phân phối theo kênh đã chọn.

## 6. Thiết kế dữ liệu cấu hình

Mô hình đề xuất:

```swift
struct AppSettings: Codable {
    var schemaVersion: Int
    var launchAtLogin: Bool
    var playback: PlaybackSettings
    var displayMode: DisplayMode
    var displayOverrides: [DisplayConfiguration]
    var recentMedia: [MediaReference]
}

struct PlaybackSettings: Codable {
    var isMuted: Bool
    var volume: Double
    var loopEnabled: Bool
    var scalingMode: ScalingMode
    var pauseOnFullscreen: Bool
    var pauseOnBattery: Bool
}

struct MediaReference: Codable {
    var identifier: UUID
    var bookmarkData: Data
    var displayName: String
    var lastKnownDuration: Double?
}
```

Không nên dùng path tuyệt đối làm nguồn dữ liệu duy nhất. Bookmark cần được resolve và refresh đúng vòng đời; dữ liệu lưu trữ phải có migration path cho những thay đổi model về sau.

## 7. Quản lý định dạng video

### Chính sách ban đầu

- Ưu tiên các định dạng được AVFoundation decode phần cứng tốt trên máy mục tiêu.
- Hiển thị codec, resolution, duration và trạng thái audio trước khi apply.
- Từ chối file thiếu track video hoặc có duration không hợp lệ.
- Không tự động transcoding trong MVP vì tốn thời gian, disk và có thể làm app khó đoán.
- Ở phiên bản sau, có thể thêm tùy chọn “Optimize for Wallpaper” chạy nền, có progress và cancel.

### Fallback khi playback lỗi

1. Hiển thị lỗi cụ thể, không chỉ “Something went wrong”.
2. Giữ wallpaper hiện tại nếu video mới không phát được.
3. Cho phép người dùng chọn file khác.
4. Ghi log kỹ thuật không chứa nội dung nhạy cảm.
5. Không retry vô hạn gây CPU load.

## 8. UI/UX đề xuất

### Menu bar

- Trạng thái ngắn: Playing, Paused, No Wallpaper hoặc Error.
- Play/Pause.
- Mute/Unmute.
- Chọn wallpaper gần đây.
- Mở Settings.
- Quit.

### Settings window

- Khu vực preview lớn ở đầu cửa sổ.
- Nút chọn video và kéo-thả.
- Thông tin file và trạng thái validation.
- Nút Apply/Remove rõ ràng.
- Nhóm Playback: loop, mute, volume, scaling.
- Nhóm Displays: main/all/per-display.
- Nhóm Behavior: launch at login, pause on fullscreen, pause on battery.

### Trạng thái bắt buộc

- Empty state chưa có video.
- Loading/validating.
- Ready to apply.
- Applying.
- Playing.
- Paused.
- Missing file.
- Unsupported format.
- Permission denied.
- Display unavailable.
- Playback failed.

## 9. Kiểm thử

### Unit tests

- Settings encode/decode và migration.
- Mapping display configuration.
- Media validation result.
- Scaling mode calculation.
- Bookmark resolve và stale bookmark handling.
- Playback state transition.
- Retry policy và error mapping.

### Integration tests

- Import video và tạo preview.
- Apply/remove wallpaper.
- Restore state sau relaunch.
- File bị xóa hoặc đổi quyền.
- Thêm/rút màn hình.
- Sleep/wake.
- Player cleanup khi thay video nhiều lần.

### UI tests

- Luồng chọn video, apply và remove.
- Các control menu bar/settings.
- Keyboard navigation và accessibility identifiers.
- Error state có action relink/chọn file khác.

### Manual matrix

- Apple Silicon và Intel nếu còn nằm trong phạm vi hỗ trợ.
- macOS version tối thiểu và version mới nhất.
- Một màn hình, hai màn hình, màn hình khác scale factor.
- 1080p, 4K, video dọc, video siêu rộng.
- Video ngắn loop nhiều lần và video dài.
- Finder relaunch, logout/login, reboot.
- Spaces, Mission Control, fullscreen app, screen lock.
- Chạy bằng pin và khi hệ thống chịu thermal pressure.

## 10. Hiệu năng và ổn định

### SLO đề xuất cho bản release đầu

- Không có memory growth đáng kể trong phiên chạy 8 giờ.
- Thời gian apply video thông thường dưới 2 giây sau khi asset ready.
- CPU trung bình ở mức chấp nhận được với video 1080p trên máy mục tiêu; cần đo thực tế thay vì đặt ngưỡng giả định.
- Không làm giật thao tác Finder hoặc chuyển cửa sổ.
- Không có player/window orphan sau ít nhất 100 lần apply/remove.

### Công cụ đo

- Instruments: Time Profiler, Allocations, Leaks, Energy Log.
- Xcode memory graph cho lifecycle object.
- `os_signpost` cho import, prepare, apply và first frame.
- Log số dropped frames và playback failure theo build.

## 11. Bảo mật và quyền riêng tư

- Chỉ xin quyền đọc file khi người dùng chọn file.
- Dùng security-scoped bookmarks nếu bật App Sandbox.
- Không upload video hoặc metadata ra ngoài nếu chưa có sự đồng ý rõ ràng.
- Không cần Accessibility permission nếu thiết kế không bắt chước thao tác người dùng.
- Không dùng private API để thao tác WindowServer hoặc desktop internals.
- Giới hạn log path và tên file nếu có nguy cơ chứa dữ liệu nhạy cảm.
- Xử lý file lỗi/corrupt an toàn, không tự thực thi nội dung từ file.

## 12. Phát hành và vận hành

### Môi trường build

- Debug: fixture videos, verbose logs, diagnostics.
- Beta: signing, crash diagnostics, migration testing.
- Release: optimized build, reduced log verbosity, notarized artifact.

### Checklist release

- Bump version/build number.
- Chạy unit, integration và UI tests trên target macOS.
- Kiểm tra entitlements và hardened runtime.
- Ký app và verify signature.
- Notarize và staple ticket nếu phân phối ngoài App Store.
- Cài mới trên máy sạch.
- Upgrade từ bản cũ.
- Kiểm tra uninstall không để lại login item gây lỗi.
- Chuẩn bị release notes và known limitations.

## 13. Backlog sau MVP

- Playlist nhiều video và chuyển theo thời gian.
- Shuffle, schedule theo giờ và theo ngày.
- Wallpaper riêng cho từng Space.
- Tự động optimize/transcode video.
- Import thư mục và theo dõi file bằng file presenter.
- Hỗ trợ Live Photo hoặc ảnh động nếu có nhu cầu.
- Preset hiệu năng theo loại máy.
- Điều khiển bằng phím tắt global nếu cần và có thiết kế permission phù hợp.
- Crash reporting opt-in.
- Preview wallpaper trên từng màn hình.

## 14. Rủi ro và phương án giảm thiểu

| Rủi ro | Mức độ | Phương án giảm thiểu |
| --- | --- | --- |
| Không thể đặt video đúng phía sau desktop icons bằng API công khai | Cao | Làm feasibility spike ở Pha 0; xác định fallback trước khi triển khai UI đầy đủ |
| Window ordering thay đổi sau Spaces/Mission Control | Cao | Test trên nhiều phiên bản macOS; tập trung logic trong `WallpaperSurface` |
| App gây tải CPU/GPU cao khi chạy lâu | Cao | Đo bằng Instruments; dùng hardware decode; thêm ResourcePolicy |
| Bookmark không còn hợp lệ sau di chuyển file | Trung bình | Hiển thị relink flow; lưu metadata hỗ trợ nhận diện file |
| Codec video không được hỗ trợ | Trung bình | Validation trước apply; giữ wallpaper cũ; hướng dẫn format |
| Màn hình cắm/rút làm orphan window | Trung bình | Centralize display notifications; test lifecycle nhiều lần |
| Mac App Store hạn chế cách tích hợp desktop | Cao | Quyết định kênh phân phối sớm; thử sandboxed prototype |
| API thay đổi giữa các macOS version | Trung bình | Deployment target rõ ràng; availability checks và compatibility layer |

## 15. Definition of Done cho MVP

- Feasibility spike xác nhận được strategy hiển thị hoặc fallback đã được chấp thuận.
- Một video hợp lệ có thể chọn, preview, apply, pause, resume, mute và loop.
- Wallpaper không chặn thao tác cửa sổ và desktop trong phạm vi hỗ trợ.
- Settings được lưu và restore qua relaunch.
- File mất quyền hoặc bị xóa có lỗi rõ ràng và flow relink.
- App xử lý sleep/wake và ít nhất một kịch bản nhiều màn hình.
- Không có crash hoặc memory leak nghiêm trọng trong test dài giờ.
- Có test tự động cho logic cốt lõi và checklist manual cho desktop integration.
- Có quyết định phân phối, signing và entitlement tương ứng.
- README được bổ sung với yêu cầu hệ thống, cách build, giới hạn đã biết và cách chạy test.

## 16. Thứ tự công việc khuyến nghị

1. Làm feasibility spike cho desktop surface.
2. Chốt deployment target và kênh phân phối.
3. Tạo skeleton app và playback prototype.
4. Implement apply/remove trên một màn hình.
5. Thêm persistence bằng security-scoped bookmark.
6. Thêm menu bar controls và settings hoàn chỉnh.
7. Implement display lifecycle và multi-display.
8. Đo hiệu năng, xử lý sleep/wake và fullscreen.
9. Bổ sung tests, accessibility và error states.
10. Ký, notarize, cài trên máy sạch và phát hành beta.

## 17. Deliverables

- Xcode project macOS native.
- Feasibility spike và ghi chú compatibility.
- Playback engine có test.
- Wallpaper surface controller.
- Settings/menu bar UI.
- Persistence model và migration.
- Multi-display coordinator.
- Test fixtures và test plan.
- Performance report.
- Release/signing documentation.
- README hướng dẫn build, chạy và giới hạn hệ thống.
