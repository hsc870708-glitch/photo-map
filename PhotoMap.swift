import AppKit
import AVFoundation
import CoreImage
import CryptoKit
import ImageIO
import MapKit
import Quartz
import QuickLookThumbnailing
import SwiftUI
import Vision

// MARK: - 설정

/// 모은 사진이 만들어지는 곳: 첫 번째 사진 폴더 안의 _사진지도/모음 (읽을 때는 건너뛴다)
var collectRoot: URL {
    (photoRoots.first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures"))
        .appendingPathComponent("_사진지도/모음")
}
let rootsDefaultsKey = "photoRoots"

/// 사진을 읽어 올 폴더들. 처음엔 비어 있고, 사용자가 고른 폴더를 UserDefaults에 저장한다
var photoRoots: [URL] = (UserDefaults.standard.stringArray(forKey: rootsDefaultsKey) ?? [])
    .map { URL(fileURLWithPath: $0) }

/// 화면에 보여줄 상대 경로. 첫 번째(기본) 폴더는 그 안의 경로만, 나머지 폴더는 폴더 이름을 앞에 붙인다
func relativePath(_ path: String) -> String {
    for (i, r) in photoRoots.enumerated() {
        let prefix = r.path + "/"
        if path.hasPrefix(prefix) {
            let rel = String(path.dropFirst(prefix.count))
            return i == 0 ? rel : r.lastPathComponent + "/" + rel
        }
    }
    return path
}
let mediaExts: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "cr3", "mp4", "mov"]
/// 앱 상태·설정을 UserDefaults에 저장하는 짧은 이름
let prefs = UserDefaults.standard
func pref<T>(_ key: String, _ fallback: T) -> T { prefs.object(forKey: key) as? T ?? fallback }

let supportDir: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("사진지도")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()
let cacheURL = supportDir.appendingPathComponent("photos-v2.json")
/// 사용자가 직접 지정한 위치. 사진 파일은 건드리지 않고 여기에만 저장한다
let manualURL = supportDir.appendingPathComponent("manual-locations.json")
/// 사용자가 우클릭으로 직접 정한 '강아지임/아님'. 자동 분석보다 우선하고, 위치 지정과 같은 식별자(이름+촬영 시각)로 저장한다
let dogLabelsURL = supportDir.appendingPathComponent("dog-labels.json")

/// 직접 지정한 위치를 저장할 때 쓰는 사진 식별자.
/// 경로 대신 '확장자 뺀 파일 이름 + 촬영 시각(초)'을 써서 파일을 다른 폴더로 옮겨도 유지된다.
/// 같은 장면의 CR3/JPG 쌍, 라이트룸에서 같은 이름으로 내보낸 JPG도 같은 사진으로 본다.
/// 촬영 시각이 없으면 어쩔 수 없이 경로를 쓴다.
func manualKey(_ p: Photo) -> String {
    guard let d = p.date else { return "path|" + p.path }
    let base = ((p.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
    return "id|\(base)|\(Int(d.timeIntervalSince1970))"
}

/// 이름을 바꿔 내보낸 파일도 찾을 수 있도록, 같은 초에 찍힌 사진은 같은 위치로 본다
func manualSecond(_ key: String) -> Int? {
    guard key.hasPrefix("id|"), let last = key.split(separator: "|").last else { return nil }
    return Int(last)
}

// MARK: - 데이터

enum LocSource: String, Codable { case gps, estimated, manual }

/// 기종 메뉴에 쓰는 이름: 카메라는 기종별로, 휴대폰은 Galaxy·iPhone으로 묶고 나머지는 '기타'
let cameraAliases: [String: String] = [
    "Canon EOS R6m2": "Canon EOS R6 Mark II",
    "ILCE-5000": "Sony α5000", "ILCE-6000": "Sony α6000", "ILCE-6400": "Sony α6400", "ILCE-7M3": "Sony α7 III", "ILCE-7M4": "Sony α7 IV",
]
let otherCamera = "기타"
func cameraName(_ model: String) -> String {
    let m = model.trimmingCharacters(in: .whitespaces)
    if m.isEmpty { return "" }
    if m.hasPrefix("SM-") || m.hasPrefix("Galaxy") || m.hasPrefix("SHV-") || m.hasPrefix("SHW-") { return "Galaxy" }
    if m.hasPrefix("iPhone") { return "iPhone" }
    if let a = cameraAliases[m] { return a }
    let cameraBrands = ["Canon ", "NIKON", "Nikon", "FUJIFILM", "X-T", "X-S", "X100", "DSC-", "ILCE-", "ILME-",
                        "E-M", "DC-", "DMC-", "PENTAX", "LEICA", "GR", "RICOH", "HERO", "FC", "DJI"]
    if cameraBrands.contains(where: { m.hasPrefix($0) }) { return m }
    return otherCamera
}

struct Photo: Codable, Identifiable, Hashable {
    let path: String
    var lat: Double?
    var lon: Double?
    let date: Date?
    var source: LocSource?
    var size: Int64? = nil
    /// 파일 내용 해시. 중복 후보(촬영 시각·크기가 같은 파일)만 계산한다
    var hash: String? = nil
    /// 파일 수정 시각. 켤 때 크기·수정 시각이 그대로인 파일은 다시 읽지 않는다
    var mtime: Double? = nil
    /// 강아지가 있는지 분석한 결과. nil이면 아직 분석 안 함. CR3·영상은 분석하지 않고 CR3는 짝 JPG 결과를 쓴다
    var dog: Bool? = nil
    /// 촬영 기종(EXIF 모델 이름). nil이면 아직 안 읽음, ""이면 정보 없음
    var cam: String? = nil

    // 화면에서 자주 쓰는 값을 한 번만 계산해 둔다(저장하지 않음, prepare()에서 채움).
    // 필터를 바꿀 때마다 6만 장의 경로 문자열을 다시 자르고 날짜를 다시 포맷하면 수백 ms씩 걸렸다
    private var cExt = "", cRel = "", cRelLower = "", cParent = "", cDay = ""
    /// 화면에 보여줄 기종 이름(예: SM-F711N → Galaxy Z Flip3)
    private(set) var camera = ""
    // 묶기·정렬용 숫자 키. 한글 경로 문자열로 묶고 정렬하면 6만 장에 수백 ms가 걸려서 숫자로 바꿔 쓴다
    private(set) var time: Double = -.infinity     // 촬영 시각(없으면 맨 앞)
    private(set) var dayID: Int = Int.min          // 현지 날짜(일 단위)
    private(set) var folderID: Int = -1            // parentFolder의 번호
    /// 촬영 시각이 없거나 믿기 어려워서 대신 쓰는 폴더 이름의 날짜(예: 190128_코타키나발루 → 2019.1.28)
    private(set) var folderDate: Date?
    /// 폴더 날짜로 바꿔 보여주는 사진인지. 이런 사진은 시간으로 위치를 추정하지 않는다
    var dateFixed: Bool { folderDate != nil }
    /// 화면에 보여주고 날짜별로 묶을 때 쓰는 날짜(위치 지정 기록은 원래 date 기준이라 그대로 둔다)
    var shownDate: Date? { folderDate ?? date }

    enum CodingKeys: String, CodingKey { case path, lat, lon, date, source, size, hash, mtime, dog, cam }

    mutating func prepare() {
        cExt = (path as NSString).pathExtension.lowercased()
        cRel = relativePath(path)
        cRelLower = cRel.lowercased()
        let dir = (cRel as NSString).deletingLastPathComponent
        cParent = dir.isEmpty ? "(최상위)" : dir
        folderDate = nil
        if useFolderDates, let fd = folderNameDate(dir) {
            // 촬영 시각이 없거나, 폴더 날짜보다 45일 넘게 뒤면(내보내거나 복사한 날로 찍힘) 폴더 날짜를 쓴다.
            // 폴더 날짜보다 앞선 사진은 실제 촬영일일 가능성이 커서 그대로 둔다(예: 260923_엄마꺼 속 옛날 사진)
            if date == nil || date!.timeIntervalSince(fd) > 45 * 86400 { folderDate = fd }
        }
        time = -.infinity
        dayID = Int.min
        cDay = shownDate.map { dayKeyFormatter.string(from: $0) } ?? "날짜 없음"
        if let d = shownDate {
            time = d.timeIntervalSince1970
            let local = time + Double(TimeZone.current.secondsFromGMT(for: d))
            dayID = Int((local / 86400).rounded(.down))
        }
        folderID = FolderIDs.id(for: cParent)
        camera = cameraName(cam ?? "")
    }

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var ext: String { cExt.isEmpty ? (path as NSString).pathExtension.lowercased() : cExt }
    var isRaw: Bool { ext == "cr3" }
    var isVideo: Bool { ext == "mp4" || ext == "mov" }
    var relative: String { cRel.isEmpty ? relativePath(path) : cRel }
    var relativeLower: String { cRelLower.isEmpty ? relative.lowercased() : cRelLower }
    var folder: String { relative.split(separator: "/").first.map(String.init) ?? "" }
    /// 사진이 들어 있는 폴더(하위 폴더까지). 최상위에 바로 있으면 "(최상위)"
    var parentFolder: String {
        if !cParent.isEmpty { return cParent }
        let dir = (relative as NSString).deletingLastPathComponent
        return dir.isEmpty ? "(최상위)" : dir
    }
    /// 날짜별로 묶을 때 쓰는 "yyyy-MM-dd"
    var dayKey: String {
        if !cDay.isEmpty { return cDay }
        return date.map { dayKeyFormatter.string(from: $0) } ?? "날짜 없음"
    }
}

/// 폴더 이름 ↔ 번호. prepare()가 백그라운드에서도 불리므로 잠금으로 보호한다
enum FolderIDs {
    private static var ids: [String: Int] = [:]
    private static let lock = NSLock()
    static func id(for name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        if let i = ids[name] { return i }
        let i = ids.count
        ids[name] = i
        return i
    }
}

/// 폴더 날짜로 보완하기(설정 창에서 끈다). prepare()가 읽는다
var useFolderDates: Bool = pref("useFolderDates", true)

/// 경로의 폴더 이름 앞 날짜(YYMMDD 또는 YYYYMMDD)를 읽는다. 가장 안쪽 폴더부터 본다. 시각은 그날 정오로 둔다
func folderNameDate(_ dir: String) -> Date? {
    for comp in dir.split(separator: "/").reversed() {
        let digits = comp.prefix { $0.isNumber }
        guard digits.count == 6 || digits.count == 8 else { continue }
        // 날짜 뒤에는 _ - 공백이 오거나 이름이 끝나야 한다(예: 190128_여행, 260322-23)
        if let next = comp.dropFirst(digits.count).first, !"_- ".contains(next) { continue }
        let n = Array(digits).map { Int(String($0))! }
        let y: Int, m: Int, d: Int
        if digits.count == 8 {
            y = n[0...3].reduce(0) { $0 * 10 + $1 }; m = n[4] * 10 + n[5]; d = n[6] * 10 + n[7]
        } else {
            y = 2000 + n[0] * 10 + n[1]; m = n[2] * 10 + n[3]; d = n[4] * 10 + n[5]
        }
        guard (1990...2100).contains(y), (1...12).contains(m), (1...31).contains(d) else { continue }
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        if let date = Calendar.current.date(from: c) { return date }
    }
    return nil
}

let dayKeyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func prepared(_ photos: [Photo]) -> [Photo] {
    var out = photos
    for i in out.indices { out[i].prepare() }
    return out
}

/// Spotlight(mdls)에 이미 색인된 촬영 시간·GPS를 읽는다. 파일을 직접 열지 않아 빠르다.
enum Scanner {
    static func run(_ exe: String, _ args: [String]) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    struct FileEntry { let path: String; let size: Int64?; let mtime: Double? }

    static func listFiles() -> [FileEntry] {
        var out: [FileEntry] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        // 폴더끼리 겹치게 등록해도(예: 사진 폴더와 그 하위 폴더) 같은 파일은 한 번만 읽는다
        var seen: Set<String> = []
        for root in photoRoots {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            while let u = en.nextObject() as? URL {
                if u.lastPathComponent == "_사진지도" { en.skipDescendants(); continue }
                if mediaExts.contains(u.pathExtension.lowercased()), seen.insert(u.path).inserted {
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    out.append(FileEntry(path: u.path, size: v?.fileSize.map(Int64.init),
                                         mtime: v?.contentModificationDate?.timeIntervalSince1970))
                }
            }
        }
        return out
    }

    /// Spotlight 색인이 없는 파일(외장 디스크 등)은 사진 파일의 EXIF를 직접 읽는다. 영상은 지원하지 않는다
    static func readEXIF(_ path: String) -> (date: Date?, lat: Double?, lon: Double?, model: String?) {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                as? [CFString: Any]
        else { return (nil, nil, nil, nil) }
        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            if let off = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
                f.dateFormat = "yyyy:MM:dd HH:mm:ssZZZZZ"
                date = f.date(from: s + off)
            }
            if date == nil {
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                f.timeZone = .current
                date = f.date(from: s)
            }
        }
        var lat: Double?, lon: Double?
        if let g = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let la = g[kCGImagePropertyGPSLatitude] as? Double, let lo = g[kCGImagePropertyGPSLongitude] as? Double {
            lat = (g[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -la : la
            lon = (g[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lo : lo
        }
        let model = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String
        return (date, lat, lon, model)
    }

    /// 파일들의 (기종, 날짜, 크기, 위도, 경도) 문자열. 속성은 이름순으로 \0 구분되어 나온다
    static func mdls(_ files: [String]) -> [String] {
        let raw = String(decoding: run("/usr/bin/mdls", ["-raw", "-nullMarker", "",
                                                        "-name", "kMDItemAcquisitionModel",
                                                        "-name", "kMDItemContentCreationDate",
                                                        "-name", "kMDItemFSSize",
                                                        "-name", "kMDItemLatitude",
                                                        "-name", "kMDItemLongitude"] + files), as: UTF8.self)
        return raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    }

    /// 파일 내용 전체의 SHA-256. 삭제 판단에 쓰이므로 일부만 읽지 않고 끝까지 읽는다
    static func contentHash(_ path: String, size: Int64) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        while let d = try? fh.read(upToCount: 4 << 20), !d.isEmpty { h.update(data: d) }
        return "full:" + h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 촬영 시각(초)과 크기가 같은 파일끼리만 내용 해시를 계산한다.
    /// 캐논 CR3처럼 연사로 찍은 서로 다른 사진이 크기까지 똑같은 경우가 있어서, 해시가 같아야 진짜 사본으로 본다
    static func hashCandidates(_ photos: inout [Photo], previous: [String: Photo],
                               progress: @escaping (Int, Int) -> Void) {
        var groups: [String: [Int]] = [:]
        for (i, p) in photos.enumerated() {
            guard let size = p.size, size > 0 else { continue }
            let k = p.date.map { "\(Int($0.timeIntervalSince1970))|\(size)" } ?? "n|\(size)"
            groups[k, default: []].append(i)
        }
        let todo = groups.values.filter { $0.count > 1 }.flatMap { $0 }
        for (n, i) in todo.enumerated() {
            let p = photos[i]
            if let h = p.hash, h.hasPrefix("full:") {
                continue
            } else if let old = previous[p.path], old.size == p.size, let h = old.hash, h.hasPrefix("full:") {
                photos[i].hash = h
            } else {
                photos[i].hash = contentHash(p.path, size: p.size!)
            }
            if n % 50 == 0 { progress(n, todo.count) }
        }
    }

    /// 폴더를 훑어서, 새로 생기거나 크기·수정 시각이 바뀐 파일만 Spotlight에서 다시 읽는다.
    /// 그대로인 파일은 이전 정보(촬영 시각, GPS, 중복 해시)를 그대로 쓴다
    static func scan(previous: [String: Photo] = [:], progress: @escaping (Int, Int) -> Void) -> [Photo] {
        let entries = listFiles()
        var photos: [Photo] = []
        photos.reserveCapacity(entries.count)
        var changed: [FileEntry] = []
        for e in entries {
            if let old = previous[e.path], old.size == e.size, let m = old.mtime, m == e.mtime {
                photos.append(old)
            } else {
                changed.append(e)
            }
        }
        let files = changed.map(\.path)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        let batchSize = 300
        for start in stride(from: 0, to: files.count, by: batchSize) {
            let batch = Array(files[start..<min(start + batchSize, files.count)])
            var fields = mdls(batch)
            // 한 파일이라도 읽기 실패하면 순서가 어긋나므로 그 묶음은 한 장씩 다시 읽는다
            let n = 5
            if fields.count != batch.count * n {
                fields = batch.flatMap { f -> [String] in
                    let one = mdls([f])
                    return one.count == n ? one : Array(repeating: "", count: n)
                }
            }
            for (i, f) in batch.enumerated() {
                let entry = changed[start + i]
                var model = fields[n * i].trimmingCharacters(in: .whitespacesAndNewlines)
                var date = fmt.date(from: fields[n * i + 1])
                var size = Int64(fields[n * i + 2])
                var lat = Double(fields[n * i + 3]), lon = Double(fields[n * i + 4])
                if fields[n * i + 1].isEmpty && fields[n * i + 2].isEmpty {
                    // Spotlight가 모르는 파일
                    size = (try? FileManager.default.attributesOfItem(atPath: f)[.size] as? NSNumber)?.int64Value
                    let ext = (f as NSString).pathExtension.lowercased()
                    if ext != "mp4" && ext != "mov" {
                        let e = readEXIF(f)
                        date = e.date; lat = e.lat; lon = e.lon; model = e.model ?? ""
                    }
                }
                var p = Photo(path: f, lat: nil, lon: nil, date: date, source: nil, size: entry.size ?? size,
                              mtime: entry.mtime)
                p.cam = model
                // 예전 캐시에는 수정 시각이 없다. 크기가 같으면 이미 계산한 중복 해시는 살려 둔다
                if let old = previous[f], old.size == p.size, old.mtime == nil { p.hash = old.hash }
                if let lat, let lon, !(lat == 0 && lon == 0) {
                    p.lat = lat
                    p.lon = lon
                    p.source = .gps
                }
                photos.append(p)
            }
            progress(min(start + batchSize, files.count), files.count)
        }
        fillCameras(&photos, progress: progress)
        return photos
    }

    /// 예전 캐시에는 기종이 없다. 처음 한 번만 Spotlight에서 기종만 따로 읽어 채운다
    static func fillCameras(_ photos: inout [Photo], progress: @escaping (Int, Int) -> Void) {
        let todo = photos.indices.filter { photos[$0].cam == nil }
        let batchSize = 500
        for start in stride(from: 0, to: todo.count, by: batchSize) {
            let idx = Array(todo[start..<min(start + batchSize, todo.count)])
            let raw = String(decoding: run("/usr/bin/mdls", ["-raw", "-nullMarker", "", "-name", "kMDItemAcquisitionModel"]
                                                + idx.map { photos[$0].path }), as: UTF8.self)
            let fields = raw.split(separator: "\0", omittingEmptySubsequences: false)
            for (k, i) in idx.enumerated() {
                photos[i].cam = fields.count == idx.count ? fields[k].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            progress(min(start + batchSize, todo.count), todo.count)
        }
    }
}

func distance(_ a: CLLocationCoordinate2D, _ lat: Double, _ lon: Double) -> Double {
    let r = Double.pi / 180
    let x = pow(sin((lat - a.latitude) * r / 2), 2)
        + cos(a.latitude * r) * cos(lat * r) * pow(sin((lon - a.longitude) * r / 2), 2)
    return 2 * 6_371_000 * asin(sqrt(x))
}

struct FolderGroup: Identifiable {
    let id: String
    let name: String
    let photos: [Photo]
}

struct DayGroup: Identifiable {
    let id: String
    let title: String
    let photos: [Photo]
}

let dayTitleFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.dateFormat = "yyyy.M.d (E)"
    return f
}()

/// 번호(인덱스)로 묶고 정렬한 뒤 마지막에 한 번만 사진을 꺼낸다. 사진 구조체를 직접 정렬하면 훨씬 느리다
private func buckets(_ idx: [Int], _ key: (Int) -> Int) -> [Int: [Int]] {
    var out: [Int: [Int]] = [:]
    for i in idx { out[key(i), default: []].append(i) }
    return out
}

private func byTime(_ photos: [Photo], _ idx: [Int]) -> [Int] {
    idx.sorted { photos[$0].time < photos[$1].time }
}

enum Mode: String, CaseIterable {
    case all = "전체", map = "장소", unlocated = "위치 없음"
}

/// 전체보기 탭의 위치 필터
enum LocFilter: String, CaseIterable {
    case any = "모두", located = "위치 있음", estimated = "추정", unlocated = "위치 없음"
}

/// 폴더 → 날짜 순으로 묶은 목록(폴더별 보기)
struct FolderSection: Identifiable {
    let id: String
    let photos: [Photo]
    let days: [FolderGroup]
}

func groupByDay(_ photos: [Photo]) -> [DayGroup] {
    let days = buckets(Array(photos.indices)) { photos[$0].dayID }
    return days.keys.sorted(by: >).map { d in
        let ps = byTime(photos, days[d]!).map { photos[$0] }
        let key = ps[0].dayKey
        let t = ps[0].shownDate.map { dayTitleFormatter.string(from: $0) } ?? key
        return DayGroup(id: key, title: "\(t) · \(ps.count)장", photos: ps)
    }
}

func groupByFolder(_ photos: [Photo]) -> [FolderSection] {
    let folders = buckets(Array(photos.indices)) { photos[$0].folderID }
    // 폴더 순서는 Finder처럼 이름순(폴더 수만큼만 비교해서 빠르다)
    let order = folders.keys.map { ($0, photos[folders[$0]![0]].parentFolder) }
        .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    return order.map { fid, name in
        let idx = byTime(photos, folders[fid]!)
        let dayB = buckets(idx) { photos[$0].dayID }
        let days = dayB.keys.sorted().map { d -> FolderGroup in
            let ps = byTime(photos, dayB[d]!).map { photos[$0] }
            let label = ps[0].shownDate.map { dayTitleFormatter.string(from: $0) } ?? ps[0].dayKey
            return FolderGroup(id: name + "/" + ps[0].dayKey, name: label, photos: ps)
        }
        return FolderSection(id: name, photos: idx.map { photos[$0] }, days: days)
    }
}

@MainActor
final class Model: ObservableObject {
    /// 아래쪽 통계 줄(사진 수)
    @Published var stats = ""
    /// 작업 결과 알림. 몇 초 뒤 사라진다(예전엔 상태 줄 앞에 계속 이어 붙여서 잘려 보였다)
    @Published var toast: String?
    private var toastTask: Task<Void, Never>?

    func notify(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self.toast = nil }
        }
    }
    @Published var mode: Mode = Mode(rawValue: pref("mode", "")) ?? .map {
        didSet {
            prefs.set(mode.rawValue, forKey: "mode")
            if showSelectedOnly { showSelectedOnly = false }
            if mode != .map { recomputeUnlocated(); recomputeAll() }
            schedulePins()
        }
    }
    // 전체보기 탭
    @Published var allFilter = "" { didSet { recomputeAll() } }
    @Published var allLocFilter: LocFilter = LocFilter(rawValue: pref("allLocFilter", "")) ?? .any {
        didSet { prefs.set(allLocFilter.rawValue, forKey: "allLocFilter"); recomputeAll() }
    }
    @Published var allByFolder: Bool = pref("allByFolder", false) { didSet { prefs.set(allByFolder, forKey: "allByFolder"); recomputeAll() } }
    @Published var allDayCount = 0
    @Published var allFolderCount = 0
    @Published var allGroups: [DayGroup] = []
    @Published var allFolders: [FolderSection] = []
    @Published var allCount = 0
    @Published var allSelected: Set<String> = []
    /// 전체보기 폴더별에서 펼쳐 둔 폴더(폴더가 많아서 기본은 접힘)
    @Published var allExpandedFolders: Set<String> = []
    /// 위치 없음 탭 안에서 날짜별/폴더별 보기
    @Published var unlocatedByFolder: Bool = pref("unlocatedByFolder", false) {
        didSet { prefs.set(unlocatedByFolder, forKey: "unlocatedByFolder"); recomputeUnlocated() }
    }
    /// 빨간 원의 중심. 마지막 장소를 기억해 두었다가 다시 켤 때 그 자리로 간다
    @Published var center: CLLocationCoordinate2D? = {
        guard let a = prefs.array(forKey: "center") as? [Double], a.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: a[0], longitude: a[1])
    }() {
        didSet { prefs.set(center.map { [$0.latitude, $0.longitude] }, forKey: "center") }
    }
    @Published var radius: Double = pref("radius", 150.0) { didSet { prefs.set(radius, forKey: "radius"); scheduleRecompute() } }
    private var pendingRecompute: Task<Void, Never>?
    @Published var includeRaw: Bool = pref("includeRaw", false) {
        didSet { prefs.set(includeRaw, forKey: "includeRaw"); refreshCameras(); recompute(); recomputeUnlocated(); recomputeAll() }
    }
    /// 시간으로 위치 추정하기. 끄면 추정했던 사진은 '위치 없음'으로 돌아간다(탭보다 위의 전체 설정)
    @Published var useEstimate: Bool = pref("useEstimate", true) { didSet { prefs.set(useEstimate, forKey: "useEstimate"); resolve() } }
    /// 폴더 이름 날짜로 보완하기(설정 창). 바꾸면 날짜를 다시 계산한다
    @Published var useFolderDates: Bool = pref("useFolderDates", true) {
        didSet {
            prefs.set(useFolderDates, forKey: "useFolderDates")
            PhotoMap.useFolderDates = useFolderDates
            all = prepared(all)
            resolve()
        }
    }
    /// 추정 시간 범위(분). 설정 창에서 바꾼다
    @Published var estimateMinutes: Int = pref("estimateMinutes", 30) {
        didSet { prefs.set(estimateMinutes, forKey: "estimateMinutes"); resolve() }
    }
    /// 추정 사진이 어느 GPS 사진의 위치를 빌렸는지(정보 창에 보여준다): 경로 → (기준 사진 경로, 시간 차 초)
    private(set) var estimateRef: [String: (path: String, dt: Double)] = [:]
    /// 지도 탭에서 '추정' 사진만 보기
    @Published var estimatedOnly = false { didSet { recompute(); schedulePins() } }
    /// 사본이 있는 사진만 보기
    @Published var duplicatesOnly = false { didSet { recompute(); recomputeUnlocated(); recomputeAll() } }
    /// 같은 파일의 사본은 하나만 보기
    /// 켜면 파일 이름(확장자 포함, 대소문자 무시)까지 같아야 중복으로 본다
    @Published var sameNameOnly = UserDefaults.standard.object(forKey: "sameNameOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sameNameOnly, forKey: "sameNameOnly"); resolve() }
    }
    @Published var oneCopyOnly = false { didSet { recompute(); recomputeUnlocated(); recomputeAll() } }
    @Published var groups: [DayGroup] = []
    @Published var folderSections: [FolderSection] = []
    /// 지도 탭 목록 보기 방식
    @Published var mapByFolder: Bool = pref("mapByFolder", false) { didSet { prefs.set(mapByFolder, forKey: "mapByFolder") } }
    /// 지도 탭 폴더별 보기에서 접어 둔 폴더(반경 안 사진은 보통 적어서 기본은 펼침)
    @Published var mapCollapsedFolders: Set<String> = []
    @Published var hitCount = 0
    @Published var searchText = ""
    @Published var results: [MKMapItem] = []
    @Published var folderName: String = pref("folderName", "") { didSet { prefs.set(folderName, forKey: "folderName") } }
    @Published var flyTo: (CLLocationCoordinate2D, UUID)?
    /// 전체보기에서 사진을 눌렀을 때 지도만 그 위치로 옮기고 표시한다(빨간 원·목록은 그대로)
    @Published var peek: (CLLocationCoordinate2D, UUID)?

    func peekAt(_ p: Photo) {
        guard let lat = p.lat, let lon = p.lon else { return }
        peek = (CLLocationCoordinate2D(latitude: lat, longitude: lon), UUID())
    }
    // 위치 없는 사진 탭
    @Published var unlocatedGroups: [DayGroup] = []
    @Published var unlocatedFolders: [FolderSection] = []
    /// 폴더별 탭에서 펼쳐 둔 폴더
    @Published var expandedFolders: Set<String> = []
    @Published var unlocatedCount = 0
    @Published var unlocatedFilter = "" { didSet { recomputeUnlocated() } }
    @Published var selected: Set<String> = []
    /// 지도 탭에서 모으기/복사할 사진. 비어 있으면 반경 안 전체를 모은다.
    /// 장소를 옮겨도 유지되므로 여러 장소의 사진을 골라 한 폴더에 모을 수 있다
    @Published var mapSelected: Set<String> = []
    /// 위치가 정해진 사진 목록이 바뀔 때마다 올라간다(지도 핀 다시 그리기용)
    @Published var locatedVersion = 0
    /// 왼쪽 지도에 핀으로 찍을 사진. 오른쪽에서 고른 필터(강아지·추정·중복 등)를 똑같이 따른다
    private(set) var pinPhotos: [Photo] = []
    @Published var pinsVersion = 0
    private var pendingPins: Task<Void, Never>?

    /// 필터를 연달아 바꾸거나 글자를 입력할 때마다 핀 수천 개를 다시 그리지 않도록 잠깐 모았다가 한 번에 그린다
    func schedulePins() {
        pendingPins?.cancel()
        pendingPins = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { self.recomputePins() }
        }
    }

    func recomputePins() {
        // RAW는 같은 장면의 JPG와 겹쳐서 핀 숫자에서는 늘 뺀다
        var list = located.filter { !$0.isRaw && passesContent($0) }
        switch mode {
        case .map:
            if estimatedOnly { list = list.filter { $0.source == .estimated } }
        case .all:
            let q = allFilter.trimmingCharacters(in: .whitespaces).lowercased()
            if !q.isEmpty { list = list.filter { ($0.relativeLower as NSString).range(of: q).location != NSNotFound } }
            switch allLocFilter {
            case .estimated: list = list.filter { $0.source == .estimated }
            case .unlocated: list = []
            case .any, .located: break
            }
        case .unlocated:
            break
        }
        pinPhotos = applyDuplicateFilters(list)
        pinsVersion += 1
    }

    /// 지도 왼쪽 위에 보여줄, 지금 핀 숫자에 걸린 필터 설명
    var pinFilterLabel: String? {
        var parts: [String] = []
        if dogOnly { parts.append("🐶 강아지만") }
        if !cameraFilter.isEmpty { parts.append("📷 " + cameraFilterLabel) }
        if mode == .map && estimatedOnly { parts.append("추정만") }
        if mode == .all {
            if allLocFilter == .estimated { parts.append("추정만") }
            if allLocFilter == .unlocated { parts.append("위치 없는 사진은 지도에 없음") }
            if !allFilter.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("'\(allFilter)' 포함") }
        }
        if duplicatesOnly { parts.append("중복만") }
        if oneCopyOnly { parts.append("중복은 1개만") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var all: [Photo] = [] { didSet { refreshCameras() } }

    /// 기종 필터. ""이면 모든 기종, noCamera면 기종 정보 없는 사진만
    static let noCamera = "기종 정보 없음"
    /// 고른 기종들(여러 개 가능). 비어 있으면 모든 기종
    @Published var cameraFilter: Set<String> = Set(pref("cameraFilters", [String]())) {
        didSet {
            guard cameraFilter != oldValue else { return }
            prefs.set(Array(cameraFilter), forKey: "cameraFilters"); recompute(); recomputeUnlocated(); recomputeAll()
        }
    }
    /// 버튼·지도에 보여줄 짧은 설명(예: "Canon EOS R8 외 2")
    var cameraFilterLabel: String {
        let names = cameraCounts.map(\.name).filter(cameraFilter.contains)
        guard let first = names.first ?? cameraFilter.first else { return "모든 기종" }
        return cameraFilter.count == 1 ? first : "\(first) 외 \(cameraFilter.count - 1)"
    }
    /// 기종별 장수(많은 순). 메뉴에 보여준다
    @Published var cameraCounts: [(name: String, count: Int)] = []
    private func refreshCameras() {
        var c: [String: Int] = [:]
        for p in all where includeRaw || !p.isRaw { c[p.camera.isEmpty ? Model.noCamera : p.camera, default: 0] += 1 }
        let tail = [otherCamera, Model.noCamera]
        let list = c.map { (name: $0.key, count: $0.value) }.sorted {
            let ta = tail.firstIndex(of: $0.name) ?? -1, tb = tail.firstIndex(of: $1.name) ?? -1
            return ta != tb ? ta < tb : $0.count > $1.count
        }
        if list.map(\.name) != cameraCounts.map(\.name) || list.map(\.count) != cameraCounts.map(\.count) { cameraCounts = list }
    }
    func passesCamera(_ p: Photo) -> Bool {
        cameraFilter.isEmpty || cameraFilter.contains(p.camera.isEmpty ? Model.noCamera : p.camera)
    }
    private(set) var located: [Photo] = []
    private var unlocated: [Photo] = []
    private var manual: [String: [Double]] = [:]
    /// 지금 '지정' 위치로 보이는 사진 경로(선택 개수 세기용)
    private var manualPaths: Set<String> = []
    private var byPath: [String: Photo] = [:]
    private var resolvedByPath: [String: Photo] = [:]
    /// 경로 → 같은 파일의 다른 사본 경로들(중복이 있는 사진만)
    private(set) var duplicates: [String: [String]] = [:]
    /// 경로 → 중복 묶음 키(사본이 있는 사진만)
    private var duplicateKey: [String: String] = [:]
    @Published var duplicateCount = 0
    private var hits: [Photo] = []

    init() {
        if let data = try? Data(contentsOf: dogLabelsURL),
           let m = try? JSONDecoder().decode([String: Bool].self, from: data) {
            dogLabels = m
        }
        if let data = try? Data(contentsOf: manualURL),
           let m = try? JSONDecoder().decode([String: [Double]].self, from: data) {
            manual = m
        }
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([Photo].self, from: data) {
            all = prepared(cached)
            resolve()
        }
        if let c = center { flyTo = (c, UUID()) }
        rescan()
        let fixed = all.filter(\.dateFixed).count
        if fixed > 0 { notify("촬영 날짜가 없거나 이상한 사진 \(fixed.formatted())장은 폴더 이름 날짜로 보여줘요") }
    }

    @Published var roots: [URL] = photoRoots
    @Published var showRoots = false

    private func saveRoots(_ list: [URL]) {
        photoRoots = list
        roots = list
        UserDefaults.standard.set(list.map(\.path), forKey: rootsDefaultsKey)
        rescan()
    }

    func addRoots() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "추가"
        panel.message = "사진지도에서 볼 사진 폴더를 고르세요"
        guard panel.runModal() == .OK else { return }
        let new = panel.urls.filter { u in !roots.contains { $0.path == u.path } }
        if !new.isEmpty { saveRoots(roots + new) }
    }

    func removeRoot(_ u: URL) {
        saveRoots(roots.filter { $0.path != u.path })
    }

    /// 화면 위쪽 진행 막대에 보여줄 오래 걸리는 작업
    struct Job: Equatable {
        var title: String
        var done: Int
        var total: Int
        var canStop: Bool
        let started = Date()

        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
        /// 남은 시간 어림(처음 몇 초는 속도가 불안정해서 보여주지 않는다)
        var remaining: String? {
            let elapsed = Date().timeIntervalSince(started)
            guard done > 0, elapsed > 3, total > done else { return nil }
            let sec = elapsed / Double(done) * Double(total - done)
            return sec < 60 ? "1분 안쪽 남음" : "약 \(Int(sec / 60) + 1)분 남음"
        }
    }
    @Published var job: Job?

    private func updateJob(_ title: String, _ done: Int, _ total: Int, canStop: Bool = false) {
        if job?.title == title { job?.done = done; job?.total = total }
        else { job = Job(title: title, done: done, total: total, canStop: canStop) }
    }

    /// 모든 탭에 함께 걸리는 '강아지만 보기' 필터
    @Published var dogOnly: Bool = pref("dogOnly", false) {
        didSet { prefs.set(dogOnly, forKey: "dogOnly"); recompute(); recomputeUnlocated(); recomputeAll() }
    }
    @Published var analyzing = false
    @Published var unanalyzedCount = 0
    private var stopAnalysis = false

    func needsAnalysis(_ p: Photo) -> Bool { p.dog == nil && analyzableExts.contains(p.ext) }

    func passesContent(_ p: Photo) -> Bool { (!dogOnly || p.dog == true) && passesCamera(p) }

    /// 사진 분석(강아지). 처음엔 오래 걸려서 버튼으로만 시작하고, 중간에 멈춰도 그때까지 결과는 남는다
    func toggleAnalysis() {
        if analyzing { stopAnalysis = true; notify("분석 멈추는 중…"); return }
        guard !buildingThumbs else { notify("썸네일을 다 만든 뒤에 분석할 수 있어요"); return }
        let todo = all.filter(needsAnalysis).map(\.path)
        guard !todo.isEmpty else { notify("분석할 새 사진이 없어요"); return }
        analyzing = true
        updateJob("🐾 사진 분석 중", 0, todo.count, canStop: true)
        stopAnalysis = false
        Task.detached {
            let chunk = 240
            var done = 0
            var sinceSave = 0
            for start in stride(from: 0, to: todo.count, by: chunk) {
                if await MainActor.run(body: { self.stopAnalysis }) { break }
                let batch = Array(todo[start..<min(start + chunk, todo.count)])
                let results = Analyzer.analyze(batch: batch)
                done += batch.count
                sinceSave += batch.count
                let save = sinceSave >= 2000
                if save { sinceSave = 0 }
                await MainActor.run {
                    self.applyAnalysis(results)
                    self.updateJob("🐾 사진 분석 중", done, todo.count, canStop: true)
                    if save { self.saveCache(); self.resolve() }
                }
            }
            await MainActor.run {
                self.analyzing = false
                self.job = nil
                self.saveCache()
                self.resolve()
                self.notify("사진 분석 \(done.formatted())장 완료")
            }
        }
    }

    private func applyAnalysis(_ results: [String: Bool]) {
        for i in all.indices {
            if let r = results[all[i].path] { all[i].dog = r }
        }
    }

    // MARK: 썸네일 만들기(전체) / 비우기 — 편집 메뉴

    /// 썸네일 위 상태 라벨(추정·지정·직접·강아지 아님·중복) 보기. 보기 메뉴에서 켜고 끈다(영상·RAW 표시는 늘 보임)
    @Published var enhanceOnDrag = PhotoMap.enhanceOnDrag {
        didSet {
            PhotoMap.enhanceOnDrag = enhanceOnDrag
            UserDefaults.standard.set(enhanceOnDrag, forKey: "enhanceOnDrag")
            if enhanceOnDrag { Enhancer.shared.warmUp() }
            notify(enhanceOnDrag ? "드래그할 때 자동 보정해서 넘겨요 (원본은 그대로)" : "드래그할 때 원본을 그대로 넘겨요")
        }
    }
    @Published var enhanceMaxSide = PhotoMap.enhanceMaxSide {
        didSet { PhotoMap.enhanceMaxSide = enhanceMaxSide; UserDefaults.standard.set(enhanceMaxSide, forKey: "enhanceMaxSide") }
    }
    @Published var showLabels = UserDefaults.standard.object(forKey: "showLabels") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showLabels, forKey: "showLabels") }
    }

    @Published var buildingThumbs = false
    private var stopThumbs = false

    /// 진행 막대의 '멈추기'
    func stopJob() {
        if analyzing { toggleAnalysis() }
        if buildingThumbs { stopThumbs = true; notify("썸네일 만들기 멈추는 중…") }
    }

    func buildAllThumbs() {
        guard !buildingThumbs else { return }
        guard !analyzing else { notify("사진 분석이 끝난 뒤에 만들 수 있어요"); return }
        let todo = all.filter { !$0.isVideo }
        buildingThumbs = true
        stopThumbs = false
        updateJob("🖼 썸네일 만드는 중", 0, todo.count, canStop: true)
        Task.detached {
            let chunk = 120
            var done = 0
            for start in stride(from: 0, to: todo.count, by: chunk) {
                if await MainActor.run(body: { self.stopThumbs }) { break }
                let batch = Array(todo[start..<min(start + chunk, todo.count)])
                DispatchQueue.concurrentPerform(iterations: batch.count) { i in ThumbStore.ensure(batch[i]) }
                done += batch.count
                let d = done
                await MainActor.run {
                    self.updateJob("🖼 썸네일 만드는 중", d, todo.count, canStop: true)
                }
            }
            let d = done
            await MainActor.run {
                self.buildingThumbs = false
                self.job = nil
                self.notify("썸네일 \(d.formatted())장 준비 완료 · 이제 처음 보는 사진도 바로 떠요")
            }
        }
    }

    func clearThumbs() {
        guard !buildingThumbs else { return }
        let bytes = ThumbStore.clear()
        ThumbCache.shared.removeAllObjects()
        notify("저장한 썸네일 \(bytes / 1_048_576)MB를 비웠어요. 볼 때 다시 만들어져요")
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: cacheURL) }
    }

    @Published var checkingDuplicates = false
    /// 중복 후보인데 아직 내용 비교를 안 한 파일 수
    @Published var uncheckedDuplicates = 0

    /// 중복 검사: 촬영 시각·크기가 같은 후보 파일만 내용 전체를 비교한다.
    /// 무거운 작업이라 켤 때 자동으로 하지 않고 버튼으로만 돌린다. 결과는 저장해 두고 다음부터 재사용한다
    func checkDuplicates() {
        guard !checkingDuplicates else { return }
        checkingDuplicates = true
        var list = all
        updateJob("📄 중복 검사 중", 0, 0)
        Task.detached {
            Scanner.hashCandidates(&list, previous: [:]) { done, total in
                Task { @MainActor in
                    self.updateJob("📄 중복 검사 중", done, total)
                }
            }
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: cacheURL) }
            await MainActor.run {
                // 검사하는 동안 다시 읽기로 목록이 바뀌었을 수 있으니 해시만 옮겨 담는다
                let hashed = Dictionary(list.compactMap { p in p.hash.map { (p.path, (hash: $0, size: p.size)) } },
                                        uniquingKeysWith: { a, _ in a })
                for i in self.all.indices where self.all[i].hash == nil {
                    if let h = hashed[self.all[i].path], h.size == self.all[i].size { self.all[i].hash = h.hash }
                }
                if let data = try? JSONEncoder().encode(self.all) { try? data.write(to: cacheURL) }
                self.checkingDuplicates = false
                self.job = nil
                self.resolve()
                self.notify("중복 검사 완료 · 중복 \(self.duplicateCount.formatted())묶음")
            }
        }
    }

    func rescan() {
        let previous = Dictionary(all.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        Task.detached {
            let found = Scanner.scan(previous: previous) { done, total in
                Task { @MainActor in
                    // 바뀐 파일이 많을 때만 막대를 띄운다(평소엔 몇 초라 깜빡이기만 한다)
                    if total > 300 { self.updateJob("↻ 새 사진 정보 읽는 중", done, total) }
                }
            }
            if let data = try? JSONEncoder().encode(found) { try? data.write(to: cacheURL) }
            let ready = prepared(found)
            await MainActor.run {
                // 읽는 동안 분석한 결과가 있으면 살려 둔다(같은 파일일 때만)
                let current = Dictionary(self.all.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                self.all = ready.map { p in
                    var p = p
                    if p.dog == nil, let c = current[p.path], c.size == p.size, c.mtime == p.mtime {
                        p.dog = c.dog
                    }
                    return p
                }
                if self.job?.title.hasPrefix("↻") == true { self.job = nil }
                self.resolve()
            }
        }
    }

    /// GPS → 직접 지정 → 시간 추정 순서로 각 사진의 위치를 정한다
    func resolve() {
        let refs: [(t: Double, lat: Double, lon: Double, path: String)] = all.compactMap { p in
            guard p.source == .gps, !p.dateFixed, let d = p.date, let lat = p.lat, let lon = p.lon else { return nil }
            return (d.timeIntervalSince1970, lat, lon, p.path)
        }.sorted { $0.t < $1.t }
        let window = Double(estimateMinutes) * 60
        var refOf: [String: (path: String, dt: Double)] = [:]

        func nearest(_ t: Double) -> (t: Double, lat: Double, lon: Double, path: String)? {
            guard !refs.isEmpty else { return nil }
            var lo = 0, hi = refs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if refs[mid].t < t { lo = mid + 1 } else { hi = mid }
            }
            let cands = [lo - 1, lo].filter { $0 >= 0 && $0 < refs.count }.map { refs[$0] }
            return cands.min { abs($0.t - t) < abs($1.t - t) }
        }

        byPath = Dictionary(all.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        // 파일 내용(해시)과 크기가 똑같아야 같은 파일의 사본으로 본다(이름이 달라도).
        // 크기·촬영 시각만 같은 연사 사진은 내용이 달라서 중복이 아니다
        var dupKeyed: [String: [String]] = [:]
        for p in all {
            guard let size = p.size, size > 0, let hash = p.hash else { continue }
            let name = sameNameOnly ? (p.path as NSString).lastPathComponent.lowercased() : ""
            let k = "h|\(hash)|\(size)|\(name)"
            dupKeyed[k, default: []].append(p.path)
        }
        var dups: [String: [String]] = [:]
        var dupKeys: [String: String] = [:]
        for (k, paths) in dupKeyed where paths.count > 1 {
            for p in paths { dups[p] = paths.filter { $0 != p }; dupKeys[p] = k }
        }
        duplicates = dups
        duplicateKey = dupKeys
        var candidates: [String: Int] = [:]
        for p in all where p.hash == nil {
            guard let size = p.size, size > 0 else { continue }
            candidates[p.date.map { "\(Int($0.timeIntervalSince1970))|\(size)" } ?? "n|\(size)", default: 0] += 1
        }
        // 해시가 없는 파일끼리, 또는 해시가 있는 파일과 시각·크기가 같으면 검사가 필요하다
        var checkedKeys: [String: Int] = [:]
        for p in all where p.hash != nil {
            guard let size = p.size else { continue }
            checkedKeys[p.date.map { "\(Int($0.timeIntervalSince1970))|\(size)" } ?? "n|\(size)", default: 0] += 1
        }
        uncheckedDuplicates = candidates.reduce(0) { acc, kv in
            acc + ((kv.value > 1 || checkedKeys[kv.key] != nil) ? kv.value : 0)
        }
        duplicateCount = dups.count
        // 예전 버전은 경로를 키로 저장했다. 지금 있는 파일이면 새 식별자로 옮긴다
        var migrated = false
        for (k, v) in manual where k.hasPrefix("/") {
            if let p = byPath[k] { manual[manualKey(p)] = v; manual[k] = nil; migrated = true }
        }
        if migrated { saveManual() }
        var bySecond: [Int: [Double]] = [:]
        for (k, v) in manual { if let t = manualSecond(k) { bySecond[t] = v } }

        // CR3는 분석하지 않고 같은 폴더·같은 이름의 JPG 결과를 쓴다
        var pairContent: [String: Bool] = [:]
        for p in all where !p.isRaw {
            if let d = p.dog { pairContent[(p.path as NSString).deletingPathExtension.lowercased()] = d }
        }
        unanalyzedCount = all.filter(needsAnalysis).count

        var loc: [Photo] = [], unloc: [Photo] = []
        var nGPS = 0, nEst = 0, nManual = 0
        let nFixed = all.reduce(0) { $0 + ($1.dateFixed ? 1 : 0) }
        var mPaths: Set<String> = []
        for var p in all {
            if p.isRaw, let c = pairContent[(p.path as NSString).deletingPathExtension.lowercased()] {
                p.dog = c
            }
            // 직접 정한 구분이 자동 분석보다 우선(같은 식별자라 CR3/JPG 쌍에 함께 적용된다)
            if !dogLabels.isEmpty, let l = dogLabels[manualKey(p)] { p.dog = l }
            if p.source == .gps {
                nGPS += 1
            } else if let m = manual[manualKey(p)] ?? p.date.flatMap({ bySecond[Int($0.timeIntervalSince1970)] }),
                      m.count == 2 {
                mPaths.insert(p.path)
                p.lat = m[0]; p.lon = m[1]; p.source = .manual
                nManual += 1
            } else if useEstimate, !p.dateFixed, let d = p.date, let n = nearest(d.timeIntervalSince1970),
                      abs(n.t - d.timeIntervalSince1970) <= window {
                p.lat = n.lat; p.lon = n.lon; p.source = .estimated
                refOf[p.path] = (n.path, d.timeIntervalSince1970 - n.t)
                nEst += 1
            } else {
                unloc.append(p)
                continue
            }
            loc.append(p)
        }
        located = loc
        unlocated = unloc
        estimateRef = refOf
        resolvedByPath = Dictionary(loc.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        manualPaths = mPaths
        locatedVersion += 1
        stats = "GPS \(nGPS.formatted()) · 추정 \(nEst.formatted()) · 지정 \(nManual.formatted()) · 위치 없음 \(unloc.count.formatted()) · 중복 \(duplicates.count.formatted())"
            + (nFixed > 0 ? " · 폴더 날짜 \(nFixed.formatted())" : "")
        recompute()
        recomputeUnlocated()
        recomputeAll()
    }

    func select(_ c: CLLocationCoordinate2D, fly: Bool = false) {
        center = c
        if fly { flyTo = (c, UUID()) }
        recompute()
    }

    /// 반경을 넓히면 사진이 수만 장이 될 수 있어서, 슬라이더를 멈춘 뒤에 목록을 다시 만든다
    func scheduleRecompute() {
        pendingRecompute?.cancel()
        pendingRecompute = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !Task.isCancelled { self.recompute() }
        }
    }

    func recompute() {
        guard let c = center else {
            groups = []; folderSections = []; hitCount = 0; hits = []
            if showSelectedOnly && mode == .map {
                hits = (located + unlocated).filter { mapSelected.contains($0.path) }
                hitCount = hits.count; groups = groupByDay(hits); folderSections = groupByFolder(hits)
            }
            return
        }
        hits = located.filter {
            (includeRaw || !$0.isRaw) && (!estimatedOnly || $0.source == .estimated) && passesContent($0)
                && distance(c, $0.lat!, $0.lon!) <= radius
        }
        hits = applyDuplicateFilters(hits)
        if showSelectedOnly && mode == .map {
            // 선택은 반경 밖이나 다른 장소 사진일 수도 있어서, 반경과 상관없이 선택한 사진만 보여준다
            hits = (located + unlocated).filter { mapSelected.contains($0.path) }
        }
        listPathCache[.map] = nil
        hitCount = hits.count
        groups = groupByDay(hits)
        folderSections = groupByFolder(hits)
    }

    /// '중복만 보기' / '중복은 1개만' 필터.
    /// 1개만 남길 때는 백업 폴더(네이버클라우드)보다 정리된 폴더에 있는 사본을, 그다음 경로가 짧은 것을 고른다
    /// 사본 중 하나만 남길 때의 우선순위(작을수록 남긴다):
    /// 백업 폴더(네이버클라우드)보다 정리된 폴더, 그다음 경로가 짧은 것
    func rank(_ p: Photo) -> (Int, Int, String) {
        (p.folder == "네이버클라우드" ? 1 : 0, p.path.count, p.path)
    }

    func applyDuplicateFilters(_ list: [Photo]) -> [Photo] {
        var out = list
        if duplicatesOnly { out = out.filter { duplicateKey[$0.path] != nil } }
        if oneCopyOnly {
            var best: [String: Photo] = [:]
            for p in out {
                guard let k = duplicateKey[p.path] else { continue }
                if let b = best[k], rank(b) <= rank(p) { continue }
                best[k] = p
            }
            out = out.filter { p in
                guard let k = duplicateKey[p.path] else { return true }
                return best[k]?.path == p.path
            }
        }
        return out
    }

    /// 위치 없음 목록. 이 탭을 볼 때만, 지금 보이는 방식(날짜별/폴더별)만 만든다
    func recomputeUnlocated() {
        schedulePins()
        guard mode == .unlocated else { return }
        let q = unlocatedFilter.trimmingCharacters(in: .whitespaces).lowercased()
        var list = unlocated.filter {
            (includeRaw || !$0.isRaw) && (q.isEmpty || ($0.relativeLower as NSString).range(of: q).location != NSNotFound) && passesContent($0)
        }
        list = applyDuplicateFilters(list)
        if showSelectedOnly { list = unlocated.filter { selected.contains($0.path) } }
        unlocatedList = list
        listPathCache[.unlocated] = nil
        unlocatedCount = list.count
        if unlocatedByFolder {
            unlocatedFolders = groupByFolder(list); unlocatedGroups = []
        } else {
            unlocatedGroups = groupByDay(list); unlocatedFolders = []
        }
    }

    func toggle(_ p: Photo) {
        if selected.contains(p.path) { selected.remove(p.path) } else { selected.insert(p.path) }
    }

    func toggleDay(_ photos: [Photo]) {
        let paths = Set(photos.map(\.path))
        if paths.isSubset(of: selected) { selected.subtract(paths) } else { selected.formUnion(paths) }
    }

    func toggleMap(_ p: Photo) {
        if mapSelected.contains(p.path) { mapSelected.remove(p.path) } else { mapSelected.insert(p.path) }
    }

    /// 전체보기 목록. 사진이 수만 장이라 전체보기 탭을 볼 때만 만든다
    func recomputeAll() {
        schedulePins()
        guard mode == .all else { return }
        let q = allFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let base: [Photo]
        switch allLocFilter {
        case .any: base = located + unlocated
        case .located: base = located
        case .estimated: base = located.filter { $0.source == .estimated }
        case .unlocated: base = unlocated
        }
        var list = base.filter {
            (includeRaw || !$0.isRaw) && (q.isEmpty || ($0.relativeLower as NSString).range(of: q).location != NSNotFound) && passesContent($0)
        }
        list = applyDuplicateFilters(list)
        if showSelectedOnly { list = (located + unlocated).filter { allSelected.contains($0.path) } }
        allList = list
        listPathCache[.all] = nil
        allCount = list.count
        allDayCount = Set(list.map(\.dayKey)).count
        allFolderCount = Set(list.map(\.parentFolder)).count
        // 지금 보이는 방식(날짜별/폴더별)만 만든다
        if allByFolder {
            allFolders = groupByFolder(list); allGroups = []
        } else {
            allGroups = groupByDay(list); allFolders = []
        }
    }

    func toggleAll(_ p: Photo) {
        if allSelected.contains(p.path) { allSelected.remove(p.path) } else { allSelected.insert(p.path) }
    }

    func toggleAllGroup(_ photos: [Photo]) {
        let paths = Set(photos.map(\.path))
        if paths.isSubset(of: allSelected) { allSelected.subtract(paths) } else { allSelected.formUnion(paths) }
    }

    // MARK: 선택 (맥 표준: 클릭=하나만, ⌘클릭=추가/빼기, ⇧클릭=범위)

    /// 지금 목록에 나온 사진(탭별). '화면 밖 선택' 세기와 ⌘A·⇧클릭에 쓴다
    private(set) var allList: [Photo] = []
    private(set) var unlocatedList: [Photo] = []
    private var listPathCache: [Mode: Set<String>] = [:]
    private var anchors: [Mode: String] = [:]
    /// 지금 탭에서 선택한 사진만 보기
    @Published var showSelectedOnly = false {
        didSet { recompute(); recomputeUnlocated(); recomputeAll() }
    }

    func selection(_ tab: Mode) -> Set<String> {
        switch tab { case .all: return allSelected; case .map: return mapSelected; case .unlocated: return selected }
    }

    func setSelection(_ tab: Mode, _ value: Set<String>) {
        switch tab { case .all: allSelected = value; case .map: mapSelected = value; case .unlocated: selected = value }
    }

    var currentSelection: Set<String> { selection(mode) }

    /// 화면에 보이는 순서대로의 사진 목록(접힌 폴더는 뺀다)
    func visibleOrder(_ tab: Mode) -> [Photo] {
        switch tab {
        case .all:
            return allByFolder ? allFolders.filter { allExpandedFolders.contains($0.id) }.flatMap(\.photos)
                               : allGroups.flatMap(\.photos)
        case .map:
            return mapByFolder ? folderSections.filter { !mapCollapsedFolders.contains($0.id) }.flatMap(\.photos)
                               : groups.flatMap(\.photos)
        case .unlocated:
            return unlocatedByFolder ? unlocatedFolders.filter { expandedFolders.contains($0.id) }.flatMap(\.photos)
                                     : unlocatedGroups.flatMap(\.photos)
        }
    }

    private func listPaths(_ tab: Mode) -> Set<String> {
        if let c = listPathCache[tab] { return c }
        let list: [Photo] = tab == .all ? allList : (tab == .map ? hits : unlocatedList)
        let set = Set(list.map(\.path))
        listPathCache[tab] = set
        return set
    }

    /// 선택했지만 지금 목록에는 없는 사진 수(장소를 옮겼거나 필터로 가려진 것)
    func hiddenSelectedCount(_ tab: Mode) -> Int {
        let sel = selection(tab)
        guard !sel.isEmpty else { return 0 }
        let visible = listPaths(tab)
        return sel.reduce(0) { $0 + (visible.contains($1) ? 0 : 1) }
    }

    /// 썸네일 클릭. 더블클릭이면 연다. 한 번 클릭과 더블클릭을 구분하려고 기다리지 않아서 바로 반응한다
    func click(_ p: Photo, in tab: Mode) {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { NSWorkspace.shared.open(p.url); return }
        let flags = NSEvent.modifierFlags
        var sel = selection(tab)
        if flags.contains(.command) {
            if sel.contains(p.path) { sel.remove(p.path) } else { sel.insert(p.path) }
        } else if flags.contains(.shift), let a = anchors[tab] {
            let order = visibleOrder(tab).map(\.path)
            if let i = order.firstIndex(of: a), let j = order.firstIndex(of: p.path) {
                sel.formUnion(order[min(i, j)...max(i, j)])
            } else {
                sel.insert(p.path)
            }
        } else {
            sel = [p.path]
        }
        if !flags.contains(.shift) { anchors[tab] = p.path }
        setSelection(tab, sel)
        cursor = p.path
        if tab == .all { peekAt(p) }
    }

    /// '이 날 전체' / '이 폴더 전체' 버튼: 이미 다 골라져 있으면 빼고, 아니면 더한다
    func toggleGroup(_ photos: [Photo], in tab: Mode) {
        var sel = selection(tab)
        let paths = Set(photos.map(\.path))
        if paths.isSubset(of: sel) { sel.subtract(paths) } else { sel.formUnion(paths) }
        setSelection(tab, sel)
    }

    func isFolderOpen(_ tab: Mode, _ id: String) -> Bool {
        switch tab {
        case .all: return allExpandedFolders.contains(id)
        case .map: return !mapCollapsedFolders.contains(id)
        case .unlocated: return expandedFolders.contains(id)
        }
    }

    func toggleFolderOpen(_ tab: Mode, _ id: String) {
        switch tab {
        case .all: if allExpandedFolders.contains(id) { allExpandedFolders.remove(id) } else { allExpandedFolders.insert(id) }
        case .map: if mapCollapsedFolders.contains(id) { mapCollapsedFolders.remove(id) } else { mapCollapsedFolders.insert(id) }
        case .unlocated: if expandedFolders.contains(id) { expandedFolders.remove(id) } else { expandedFolders.insert(id) }
        }
    }

    func expandAllFolders(_ tab: Mode, _ open: Bool) {
        switch tab {
        case .all: allExpandedFolders = open ? Set(allFolders.map(\.id)) : []
        case .map: mapCollapsedFolders = open ? [] : Set(folderSections.map(\.id))
        case .unlocated: expandedFolders = open ? Set(unlocatedFolders.map(\.id)) : []
        }
    }

    /// 지금 탭의 선택을 빨간 원 중심 위치로 지정
    func assignCurrentSelection() {
        switch mode {
        case .all: assignAllSelected()
        case .map: assignMapSelected()
        case .unlocated: assignSelected()
        }
    }

    /// 작업 막대의 강아지 메뉴: 지금 탭의 선택 전체에 적용
    func setDogForSelection(_ value: Bool?) {
        let sel = currentSelection
        guard let first = sel.first, let p = byPath[first] else { return }
        setDog(p, selection: sel, value)
    }

    /// 키보드로 움직이는 현재 칸(선택의 기준점). 바뀌면 목록이 그 칸까지 스크롤한다
    @Published var cursor: String?
    /// 목록 폭에 맞춰 한 줄에 들어가는 썸네일 수(위아래 화살표 이동용)
    var gridColumnCount = 4

    /// 화살표 키: ←→ 한 칸, ↑↓ 한 줄. ⇧를 누르면 선택을 넓힌다
    func moveCursor(_ step: Int, extend: Bool) {
        let order = visibleOrder(mode)
        guard !order.isEmpty else { return }
        let from = cursor ?? anchors[mode] ?? currentSelection.first
        let i = from.flatMap { f in order.firstIndex { $0.path == f } }
        let j = i.map { min(max($0 + step, 0), order.count - 1) } ?? 0
        let target = order[j]
        if extend, let a = anchors[mode], let ai = order.firstIndex(where: { $0.path == a }) {
            setSelection(mode, Set(order[min(ai, j)...max(ai, j)].map(\.path)))
        } else {
            setSelection(mode, [target.path])
            anchors[mode] = target.path
        }
        cursor = target.path
        if mode == .all { peekAt(target) }
    }

    /// 엔터: 선택한 사진 열기(너무 많으면 앞의 20장만)
    func openSelection() {
        let order = visibleOrder(mode).filter { currentSelection.contains($0.path) }
        for p in order.prefix(20) { NSWorkspace.shared.open(p.url) }
    }

    /// 선택한 사진을 끌 때 함께 끌 파일(보이는 순서). 선택 밖의 사진을 끌면 그 한 장만
    func dragURLs(for p: Photo, in tab: Mode) -> [URL] {
        let sel = selection(tab)
        guard sel.contains(p.path), sel.count > 1 else { return [p.url] }
        let order = visibleOrder(tab).filter { sel.contains($0.path) }.map(\.url)
        let hidden = sel.subtracting(order.map(\.path)).compactMap { photo($0)?.url }
        return order + hidden
    }

    /// 정보 창에 보여줄 사진: 지금 탭에서 마지막으로 고른 사진
    var infoPhoto: Photo? {
        let sel = currentSelection
        if let c = cursor, sel.contains(c) { return photo(c) }
        if let a = anchors[mode], sel.contains(a) { return photo(a) }
        return sel.first.flatMap { photo($0) }
    }

    /// 여러 장 골랐을 때 정보 창 요약
    func selectionSummary() -> (count: Int, gps: Int, est: Int, manual: Int, none: Int, dogs: Int, from: Date?, to: Date?) {
        let ps = currentSelection.compactMap { photo($0) }
        let dates = ps.compactMap(\.shownDate)
        return (ps.count,
                ps.filter { $0.source == .gps }.count, ps.filter { $0.source == .estimated }.count,
                ps.filter { $0.source == .manual }.count, ps.filter { $0.source == nil }.count,
                ps.filter { $0.dog == true }.count, dates.min(), dates.max())
    }

    /// 설정 창용: 저장한 썸네일 용량(파일이 수만 개라 뒤에서 센다)
    @Published var thumbBytes: Int?
    func refreshThumbBytes() {
        thumbBytes = nil
        Task.detached {
            let files = (try? FileManager.default.contentsOfDirectory(at: ThumbStore.dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            await MainActor.run { self.thumbBytes = bytes }
        }
    }

    var analyzedCount: Int { all.filter { $0.dog != nil }.count }
    var totalCount: Int { all.count }

    func selectAllVisible() { setSelection(mode, Set(visibleOrder(mode).map(\.path))) }

    func clearSelection() {
        setSelection(mode, [])
        if showSelectedOnly { showSelectedOnly = false }
    }

    /// 스페이스바 미리보기에 넘길 사진: 여러 장 골랐으면 고른 사진, 아니면 보이는 목록 전체(화살표로 넘겨 보기)
    func previewItems() -> (urls: [URL], start: Int) {
        let order = visibleOrder(mode)
        let sel = currentSelection
        if sel.count > 1 {
            let picked = order.filter { sel.contains($0.path) }
            return (picked.map(\.url), 0)
        }
        let start = sel.first.flatMap { s in order.firstIndex { $0.path == s } } ?? 0
        return (order.map(\.url), start)
    }

    // MARK: 되돌리기(⌘Z)

    struct UndoStep {
        let name: String
        var manual: [String: [Double]]?
        var dogLabels: [String: Bool]?
        /// 휴지통으로 옮긴 파일: (원래 자리, 휴지통 안 자리, 사진 정보)
        var trashed: [(from: URL, to: URL, photo: Photo)] = []
    }
    @Published private(set) var undoStack: [UndoStep] = []
    @Published private(set) var redoStack: [UndoStep] = []

    private func snapshot(_ name: String) -> UndoStep { UndoStep(name: name, manual: manual, dogLabels: dogLabels) }

    /// 위치 지정·지우기, 강아지 구분처럼 기록만 바뀌는 작업 전에 부른다
    private func pushUndo(_ name: String) {
        undoStack.append(snapshot(name))
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var undoTitle: String? { undoStack.last.map { "되돌리기: \($0.name)" } }
    var redoTitle: String? { redoStack.last.map { "다시 실행: \($0.name)" } }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        if !step.trashed.isEmpty {
            // 휴지통에서 원래 자리로 되돌린다
            var back = 0
            for t in step.trashed where (try? FileManager.default.moveItem(at: t.to, to: t.from)) != nil {
                all.append(t.photo); back += 1
            }
            saveCache(); resolve()
            notify("\(back)장을 휴지통에서 원래 자리로 되돌렸어요")
            return
        }
        redoStack.append(snapshot(step.name))
        restore(step)
        notify("되돌렸어요: \(step.name)")
    }

    func redo() {
        guard let step = redoStack.popLast() else { return }
        undoStack.append(snapshot(step.name))
        restore(step)
        notify("다시 실행했어요: \(step.name)")
    }

    private func restore(_ step: UndoStep) {
        if let m = step.manual { manual = m; saveManual() }
        if let d = step.dogLabels {
            dogLabels = d
            if let data = try? JSONEncoder().encode(dogLabels) { try? data.write(to: dogLabelsURL) }
        }
        resolve()
    }

    // MARK: 모으기(이름 묻기) · 썸네일 크기

    /// '모으기'를 누르면 폴더 이름을 묻는 창을 띄운다
    struct CollectRequest { let copy: Bool; let items: [Photo] }
    @Published var collectRequest: CollectRequest?

    func requestCollect(copy: Bool, items: [Photo]) {
        guard !items.isEmpty else { return }
        collectRequest = CollectRequest(copy: copy, items: items)
    }

    /// 선택한 사진(없으면 장소 탭은 반경 안 전체)
    func collectTargets() -> [Photo] {
        let sel = currentSelection
        if sel.isEmpty { return mode == .map ? hits : [] }
        return sel.compactMap { photo($0) }
    }

    @Published var thumbSize: Double = UserDefaults.standard.object(forKey: "thumbSize") as? Double ?? 96 {
        didSet { UserDefaults.standard.set(thumbSize, forKey: "thumbSize") }
    }
    func zoomThumbs(_ step: Double) { thumbSize = min(200, max(64, thumbSize + step)) }

    /// 위치까지 정해진 사진(위치 없으면 원본 정보)
    func photo(_ path: String) -> Photo? { resolvedByPath[path] ?? byPath[path] }

    /// 전체보기에서 고른 사진의 위치로 지도 탭을 연다
    func showOnMap(_ p: Photo) {
        guard let lat = p.lat, let lon = p.lon else { return }
        mode = .map
        select(CLLocationCoordinate2D(latitude: lat, longitude: lon), fly: true)
    }

    func toggleMapDay(_ photos: [Photo]) {
        let paths = Set(photos.map(\.path))
        if paths.isSubset(of: mapSelected) { mapSelected.subtract(paths) } else { mapSelected.formUnion(paths) }
    }

    /// 선택한 사진을 지도에서 고른 위치(빨간 원의 중심)에 있다고 저장한다
    func assignSelected() {
        assign(selected)
        selected.removeAll()
    }

    /// 지도 탭에서 고른 사진을 빨간 원의 중심 위치로 지정한다.
    /// 선택은 장소를 옮겨도 유지되므로, 사진을 고른 뒤 맞는 장소를 검색·클릭하고 누르면 된다
    func assignMapSelected() {
        assign(mapSelected)
        mapSelected.removeAll()
    }

    /// 선택 중 '추정' 사진 수
    func estimatedCount(in paths: Set<String>) -> Int {
        paths.filter { resolvedByPath[$0]?.source == .estimated }.count
    }

    /// 추정 위치가 맞다고 확인한 사진을 그 위치 그대로 '지정'으로 굳힌다
    func confirmEstimated(_ paths: Set<String>) {
        let items = paths.compactMap { resolvedByPath[$0] }.filter { $0.source == .estimated }
        guard !items.isEmpty else { return }
        pushUndo("추정 위치 확정 \(items.count)장")
        for p in items { manual[manualKey(p)] = [p.lat!, p.lon!] }
        mapSelected.subtract(items.map(\.path))
        allSelected.subtract(items.map(\.path))
        saveManual()
        resolve()
        notify("\(items.count)장의 추정 위치를 확정했어요")
    }

    /// 전체보기에서 고른 사진(추정 사진 바로잡기 등)을 빨간 원의 중심 위치로 지정한다
    func assignAllSelected() {
        assign(allSelected)
        allSelected.removeAll()
    }

    private func assign(_ paths: Set<String>) {
        guard let c = center, !paths.isEmpty else { return }
        let n = paths.count
        pushUndo("위치 지정 \(n)장")
        for path in paths {
            if let p = byPath[path] { manual[manualKey(p)] = [c.latitude, c.longitude] }
        }
        saveManual()
        resolve()
        notify("\(n)장에 위치를 지정했어요")
    }

    /// 이 사진의 지정 위치를 지운다. 같은 초에 찍힌 사진(CR3/JPG 쌍, 내보낸 파일)의 지정도 함께 지워진다
    private func removeManual(_ p: Photo) {
        manual[manualKey(p)] = nil
        manual["path|" + p.path] = nil
        manual[p.path] = nil
        if let d = p.date {
            let t = Int(d.timeIntervalSince1970)
            for k in manual.keys where manualSecond(k) == t { manual[k] = nil }
        }
    }

    func unassign(_ p: Photo) {
        pushUndo("지정 위치 지우기")
        removeManual(p)
        saveManual()
        resolve()
    }

    /// 지도 탭에서 선택한 사진 중 직접 지정한 것들의 위치를 한꺼번에 지운다
    func unassignSelected() {
        let paths = currentSelection.intersection(manualPaths)
        guard !paths.isEmpty else { return }
        pushUndo("지정 위치 지우기 \(paths.count)장")
        for path in paths { if let p = byPath[path] { removeManual(p) } }
        setSelection(mode, currentSelection.subtracting(paths))
        saveManual()
        resolve()
        notify("\(paths.count)장의 지정 위치를 지웠어요")
    }

    /// 지금 탭 선택 중 '지정' 사진 수
    var selectedManualCount: Int { currentSelection.intersection(manualPaths).count }

    // MARK: 휴지통으로 이동

    /// 확인 창에 띄울 삭제 대기 목록. nil이 아니면 확인 창이 뜬다
    @Published var pendingDelete: [Photo]?

    /// 같은 폴더에 있는 같은 이름의 다른 확장자 파일(CR3/JPG 쌍 등)
    func pairs(of photos: [Photo]) -> [Photo] {
        func key(_ p: Photo) -> String {
            ((p.path as NSString).deletingPathExtension).lowercased()
        }
        let chosen = Set(photos.map(\.path))
        let keys = Set(photos.map(key))
        return all.filter { keys.contains(key($0)) && !chosen.contains($0.path) }
    }

    /// 사진 하나를 우클릭했을 때: 그 사진이 선택 안에 있으면 선택 전체, 아니면 그 사진만
    func requestDelete(_ p: Photo, selection: Set<String>) {
        let paths = selection.contains(p.path) ? selection : [p.path]
        pendingDelete = paths.compactMap { byPath[$0] }
    }

    func requestDelete(selection: Set<String>) {
        pendingDelete = selection.compactMap { byPath[$0] }
    }

    /// 실제로 지울 목록과, 사본이 전부 선택돼서 하나씩 남겨 둘 사진.
    /// 같은 파일의 모든 사본을 한꺼번에 지우면 사진이 아예 없어지므로 가장 좋은 사본 하나는 지우지 않는다
    func deletePlan(includePairs: Bool) -> (delete: [Photo], kept: [Photo]) {
        let chosen = pendingDelete ?? []
        let chosenPaths = Set(chosen.map(\.path))
        var kept: [Photo] = []
        var doneKeys: Set<String> = []
        for p in chosen {
            guard let k = duplicateKey[p.path], doneKeys.insert(k).inserted else { continue }
            let members = [p.path] + (duplicates[p.path] ?? [])
            if members.allSatisfy(chosenPaths.contains),
               let keep = members.compactMap({ byPath[$0] }).min(by: { rank($0) < rank($1) }) {
                kept.append(keep)
            }
        }
        let keptPaths = Set(kept.map(\.path))
        var items = chosen.filter { !keptPaths.contains($0.path) }
        if includePairs { items += pairs(of: items).filter { !keptPaths.contains($0.path) } }
        return (items, kept)
    }

    func performDelete(includePairs: Bool) {
        guard pendingDelete != nil else { return }
        let items = deletePlan(includePairs: includePairs).delete
        pendingDelete = nil
        var trashed: Set<String> = []
        var failed = 0
        var step = UndoStep(name: "휴지통으로 이동 \(items.count)장")
        for p in items {
            // 완전 삭제가 아니라 휴지통으로 옮긴다(Finder에서 되살릴 수 있고, ⌘Z로도 되돌린다)
            var inTrash: NSURL?
            if (try? FileManager.default.trashItem(at: p.url, resultingItemURL: &inTrash)) != nil {
                trashed.insert(p.path)
                if let t = inTrash as URL?, let orig = byPath[p.path] { step.trashed.append((p.url, t, orig)) }
            } else {
                failed += 1
            }
        }
        if !step.trashed.isEmpty {
            undoStack.append(step)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        all.removeAll { trashed.contains($0.path) }
        selected.subtract(trashed)
        mapSelected.subtract(trashed)
        allSelected.subtract(trashed)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: cacheURL) }
        resolve()
        notify("\(trashed.count)장을 휴지통으로 옮겼어요 · ⌘Z로 되돌릴 수 있어요" + (failed > 0 ? " (\(failed)장 실패)" : ""))
    }

    // MARK: 강아지 직접 구분

    private var dogLabels: [String: Bool] = [:]

    func dogLabel(_ p: Photo) -> Bool? { dogLabels.isEmpty ? nil : dogLabels[manualKey(p)] }

    /// 우클릭한 사진이 선택 안에 있으면 선택 전체에, 아니면 그 사진에만 적용한다. nil이면 직접 구분을 지우고 자동 분석으로 돌아간다
    func setDog(_ p: Photo, selection: Set<String>, _ value: Bool?) {
        let paths = selection.contains(p.path) ? selection : [p.path]
        pushUndo(value == nil ? "강아지 구분 지우기" : (value! ? "강아지임" : "강아지 아님"))
        for path in paths {
            guard let ph = byPath[path] else { continue }
            dogLabels[manualKey(ph)] = value
        }
        if let data = try? JSONEncoder().encode(dogLabels) { try? data.write(to: dogLabelsURL) }
        resolve()
        let what = value == nil ? "자동 분석으로 되돌렸어요" : (value! ? "'강아지임'으로 정했어요" : "'강아지 아님'으로 정했어요")
        notify("\(paths.count)장을 \(what)")
    }

    private func saveManual() {
        if let data = try? JSONEncoder().encode(manual) { try? data.write(to: manualURL) }
    }

    func search() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        // "35.8, 128.6" 처럼 좌표를 붙여넣은 경우
        let nums = q.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        if nums.count == 2 {
            results = []
            select(CLLocationCoordinate2D(latitude: nums[0], longitude: nums[1]), fly: true)
            return
        }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 36.3, longitude: 127.8),
                                        span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6))
        MKLocalSearch(request: req).start { resp, _ in
            Task { @MainActor in
                self.results = Array((resp?.mapItems ?? []).prefix(8))
                if self.results.isEmpty { self.notify("'\(q)' 검색 결과가 없어요. 지도를 직접 클릭해 보세요") }
            }
        }
    }

    func pick(_ item: MKMapItem) {
        results = []
        folderName = item.name ?? ""
        select(item.placemark.coordinate, fly: true)
    }

    /// 반경 안 사진을 한 폴더로 모은다. 기본은 바로가기(심볼릭 링크), copy면 실제 복사.
    func collect(copy: Bool, items given: [Photo]? = nil) {
        let name = folderName.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let dest = collectRoot.appendingPathComponent(name.isEmpty ? "모음" : name)
        let items = given ?? (mapSelected.isEmpty ? hits : located.filter { mapSelected.contains($0.path) })
        notify("\(items.count)장 모으는 중…")
        Task.detached {
            let fm = FileManager.default
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            for p in items {
                // 날짜를 앞에 붙여 정렬되게 하고, 다른 폴더의 같은 파일명 충돌도 줄인다
                let prefix = p.shownDate.map { fmt.string(from: $0) + "_" } ?? ""
                let target = dest.appendingPathComponent(prefix + p.url.lastPathComponent)
                if copy { try? fm.copyItem(at: p.url, to: target) }
                else { try? fm.createSymbolicLink(at: target, withDestinationURL: p.url) }
            }
            await MainActor.run {
                self.notify("\(items.count)장 → 모음/\(dest.lastPathComponent)")
                NSWorkspace.shared.open(dest)
            }
        }
    }
}

// MARK: - 사진 분석(강아지)

let analyzableExts: Set<String> = ["jpg", "jpeg", "png", "heic", "gif"]

enum Analyzer {
    /// macOS 내장 Vision으로 강아지가 있는지 본다. 인터넷으로 보내지 않고 맥 안에서만 처리한다
    static func analyze(_ path: String) -> Bool? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        // 원본 대신 640px로 줄여 읽어서 빠르게 분석한다
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let animals = VNRecognizeAnimalsRequest()
        // 흐리거나 잘린 강아지는 위치 찾기(animals)가 놓쳐서, 사진 전체 분류(classify)도 함께 본다
        let classify = VNClassifyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: img, options: [:]).perform([animals, classify])) != nil
        else { return nil }
        // 배경에 아주 작게 찍힌 것까지 잡지 않도록 사진의 0.5% 이상 크기만 센다
        func bigEnough(_ box: CGRect) -> Bool { box.width * box.height >= 0.005 }
        let boxDog = (animals.results ?? []).contains { o in
            bigEnough(o.boundingBox) && o.labels.contains { $0.identifier == VNAnimalIdentifier.dog.rawValue && $0.confidence >= 0.3 }
        }
        // 흰 강아지가 흰 이불 위에 있는 사진처럼 애매한 경우 점수가 낮게 나와서 기준을 낮게 잡는다.
        // (가족·자동차 사진 표본에서 이 기준으로도 강아지 오판은 없었다)
        let classDog = (classify.results ?? []).contains { ($0.identifier == "dog" || $0.identifier == "canine") && $0.confidence >= 0.15 }
        let dog = boxDog || classDog
        return dog
    }

    /// 여러 장을 CPU 코어 수만큼 동시에 분석한다
    static func analyze(batch: [String]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: batch.count) { i in
            let r = analyze(batch[i]) ?? false
            lock.lock(); out[batch[i]] = r; lock.unlock()
        }
        return out
    }
}

// MARK: - 지도

/// 핀·라벨 색: GPS 주황, 추정 파랑, 지정 보라
func pinNSColor(_ k: LocSource) -> NSColor {
    switch k { case .gps: return .systemOrange; case .estimated: return .systemBlue; case .manual: return .systemPurple }
}
func pinColor(_ k: LocSource) -> Color { Color(nsColor: pinNSColor(k)) }

/// 전체보기에서 누른 사진의 위치 표시(보라색 카메라 핀)
final class PeekAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    init(_ c: CLLocationCoordinate2D) { coordinate = c }
}

final class CellAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let count: Int
    let kind: LocSource
    init(_ c: CLLocationCoordinate2D, _ n: Int, _ k: LocSource) { coordinate = c; count = n; kind = k }
}

func shortCount(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }

struct MapView: NSViewRepresentable {
    @ObservedObject var model: Model

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        // 사진 핀이 눈에 띄도록 지도를 차분하게, 장소 이름은 블로그에 쓸 만한 것(식당·카페·공원·숙소 등)만 보인다
        let cfg = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        cfg.pointOfInterestFilter = MKPointOfInterestFilter(including: [
            .restaurant, .cafe, .bakery, .brewery, .winery, .park, .nationalPark, .beach, .campground,
            .hotel, .museum, .zoo, .aquarium, .amusementPark, .marina, .stadium, .theater,
        ])
        mv.preferredConfiguration = cfg
        mv.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35.87, longitude: 128.6),
                                        latitudinalMeters: 30000, longitudinalMeters: 30000), animated: false)
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.click(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        mv.addGestureRecognizer(click)
        return mv
    }

    func updateNSView(_ mv: MKMapView, context: Context) {
        let co = context.coordinator
        if co.version != model.pinsVersion {
            co.version = model.pinsVersion
            mv.removeAnnotations(mv.annotations)
            // 약 20m 격자로 묶어 핀 개수를 줄인다. GPS·추정·지정은 색이 달라서 따로 묶는다
            var cells: [String: (Double, Double, Int, LocSource)] = [:]
            for p in model.pinPhotos {
                let lat = p.lat!, lon = p.lon!
                let kind = p.source ?? .gps
                let k = "\(kind.rawValue)|\(Int((lat / 0.0002).rounded())),\(Int((lon / 0.0002).rounded()))"
                let c = cells[k] ?? (0, 0, 0, kind)
                cells[k] = (c.0 + lat, c.1 + lon, c.2 + 1, kind)
            }
            mv.addAnnotations(cells.values.map {
                CellAnnotation(CLLocationCoordinate2D(latitude: $0.0 / Double($0.2), longitude: $0.1 / Double($0.2)), $0.2, $0.3)
            })
            if let pin = co.peekPin { mv.addAnnotation(pin) }
        }
        if let (c, token) = model.peek, token != co.peekToken {
            co.peekToken = token
            if let old = co.peekPin { mv.removeAnnotation(old) }
            let pin = PeekAnnotation(c)
            co.peekPin = pin
            mv.addAnnotation(pin)
            // 너무 멀리 축소돼 있으면 동네가 보이게 확대하고, 아니면 지금 줌 그대로 가운데로만 옮긴다
            if mv.region.span.latitudeDelta > 0.1 {
                mv.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: 3000, longitudinalMeters: 3000), animated: true)
            } else {
                mv.setCenter(c, animated: true)
            }
        }
        if let (c, token) = model.flyTo, token != co.flyToken {
            co.flyToken = token
            // 반경보다 넉넉하게 보여줘서 주변 동네도 같이 보이게 한다(반경 150m 기준 약 1.5km 폭)
            let m = max(model.radius * 10, 1500)
            mv.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: m, longitudinalMeters: m), animated: true)
        }
        if let c = model.center {
            if co.circleCenter?.latitude != c.latitude || co.circleCenter?.longitude != c.longitude || co.circleRadius != model.radius {
                co.circleCenter = c
                co.circleRadius = model.radius
                mv.removeOverlays(mv.overlays)
                mv.addOverlay(MKCircle(center: c, radius: model.radius))
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let model: Model
        var version = -1
        var flyToken: UUID?
        var peekToken: UUID?
        var peekPin: PeekAnnotation?
        var circleCenter: CLLocationCoordinate2D?
        var circleRadius: Double = 0
        init(_ m: Model) { model = m }

        @objc func click(_ g: NSClickGestureRecognizer) {
            guard let mv = g.view as? MKMapView else { return }
            let p = g.location(in: mv)
            // 핀을 누른 경우는 didSelect에서 처리한다
            for a in mv.annotations {
                if let v = mv.view(for: a), !v.isHidden, v.convert(v.bounds, to: mv).contains(p) { return }
            }
            let c = mv.convert(p, toCoordinateFrom: mv)
            Task { @MainActor in self.model.select(c) }
        }

        func mapView(_ mv: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cl = annotation as? MKClusterAnnotation {
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "cluster") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: cl, reuseIdentifier: "cluster")
                v.annotation = cl
                v.glyphText = shortCount(cl.memberAnnotations.compactMap { ($0 as? CellAnnotation)?.count }.reduce(0, +))
                v.markerTintColor = pinNSColor((cl.memberAnnotations.first as? CellAnnotation)?.kind ?? .gps)
                // 묶음 핀 옆에 macOS가 붙이는 "+2 more" 글자는 숫자와 헷갈려서 숨긴다
                v.titleVisibility = .hidden
                v.subtitleVisibility = .hidden
                v.displayPriority = .required
                return v
            }
            if let pin = annotation as? PeekAnnotation {
                let v = mv.dequeueReusableAnnotationView(withIdentifier: "peek") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: "peek")
                v.annotation = pin
                // 핀 색(주황·파랑·보라)과 겹치지 않게 분홍
                v.markerTintColor = .systemPink
                v.glyphImage = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)
                v.displayPriority = .required
                v.clusteringIdentifier = nil
                return v
            }
            guard let cell = annotation as? CellAnnotation else { return nil }
            let v = mv.dequeueReusableAnnotationView(withIdentifier: "cell") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: cell, reuseIdentifier: "cell")
            v.annotation = cell
            v.clusteringIdentifier = cell.kind.rawValue
            v.glyphText = shortCount(cell.count)
            v.markerTintColor = pinNSColor(cell.kind)
            v.titleVisibility = .hidden
            v.subtitleVisibility = .hidden
            return v
        }

        func mapView(_ mv: MKMapView, didSelect view: MKAnnotationView) {
            guard let a = view.annotation else { return }
            if a is PeekAnnotation { mv.deselectAnnotation(a, animated: false); return }
            mv.deselectAnnotation(a, animated: false)
            if let cl = a as? MKClusterAnnotation {
                mv.showAnnotations(cl.memberAnnotations, animated: true)
            } else {
                let c = a.coordinate
                Task { @MainActor in self.model.select(c) }
            }
        }

        func mapView(_ mv: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let r = MKCircleRenderer(overlay: overlay)
            r.strokeColor = .systemRed
            r.lineWidth = 2
            r.fillColor = NSColor.systemRed.withAlphaComponent(0.08)
            return r
        }
    }
}

// MARK: - 썸네일

/// 썸네일 만들기와 디스크 저장.
/// 사진 파일 안에 이미 들어 있는 미리보기를 꺼내 쓰고(훑어보기보다 2배 이상 빠름),
/// 만든 썸네일은 작은 JPEG로 저장해 두어 다음에는 파일만 읽는다
enum ThumbStore {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("사진지도/thumbs")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    /// 한꺼번에 너무 많이 만들면 오히려 느려져서 동시에 6장까지만
    private static let gate = DispatchSemaphore(value: 6)

    /// 파일이 바뀌면(크기·수정 시각) 새로 만들도록 키에 넣는다
    static func file(for p: Photo) -> URL {
        let key = "\(p.path)|\(p.size ?? 0)|\(p.mtime ?? 0)"
        let h = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(h + ".jpg")
    }

    private static func make(_ src: CGImageSource, always: Bool) -> CGImage? {
        let o: [CFString: Any] = [
            always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
    }

    /// 영상 등 사진이 아닌 파일은 nil(호출한 쪽이 훑어보기로 만든다)
    static func image(for p: Photo) -> NSImage? {
        if let d = try? Data(contentsOf: file(for: p)), let img = NSImage(data: d) { return img }
        return create(p).map { NSImage(cgImage: $0, size: .zero) }
    }

    /// '썸네일 만들기(전체)'용: 이미 저장돼 있으면 아무것도 안 한다
    static func ensure(_ p: Photo) {
        if !FileManager.default.fileExists(atPath: file(for: p).path) { _ = create(p) }
    }

    /// 저장한 썸네일을 모두 지우고 지운 용량(바이트)을 돌려준다
    static func clear() -> Int {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return bytes
    }

    /// 썸네일을 새로 만들어 저장한다. 영상은 nil(훑어보기로 만든다)
    private static func create(_ p: Photo) -> CGImage? {
        let cached = file(for: p)
        if p.isVideo { return nil }
        gate.wait(); defer { gate.signal() }
        guard let src = CGImageSourceCreateWithURL(p.url as CFURL, nil) else { return nil }
        var cg = make(src, always: false)
        // 들어 있는 미리보기가 너무 작으면(160px 등) 원본에서 줄여 만든다. CR3는 원본 현상이 느려서 하지 않는다
        if !p.isRaw, cg == nil || max(cg!.width, cg!.height) < 240 { cg = make(src, always: true) }
        guard let cg else { return nil }
        if let dest = CGImageDestinationCreateWithURL(cached as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        return cg
    }
}

final class ThumbCache {
    static let shared: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 3000   // 썸네일을 끝없이 쌓아 메모리를 2GB 넘게 쓰던 것을 막는다
        return c
    }()
}

// 이 환경(CommandLineTools)에는 @State 매크로 플러그인이 없어서 작은 ObservableObject로 대신한다
final class ThumbLoader: ObservableObject {
    @Published var image: NSImage?
}

func tagLabel(_ text: String, _ color: Color) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(color).foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 3)).padding(4)
}

struct Thumb: View {
    @Environment(\.openWindow) private var openWindow
    let photo: Photo
    var isSelected = false
    /// 클릭(선택 규칙과 더블클릭 열기는 Model.click이 처리한다)
    var onClick: (() -> Void)?
    var onUnassign: (() -> Void)?
    var unassignTitle = "지정한 위치 지우기"
    var onTrash: (() -> Void)?
    var trashTitle = "휴지통으로 이동"
    /// 같은 파일의 다른 사본 경로
    var copies: [String] = []
    var onShowOnMap: (() -> Void)?
    /// 직접 정한 강아지 구분(nil이면 자동 분석 결과를 씀)
    var dogLabel: Bool? = nil
    var onSetDog: ((Bool?) -> Void)?
    /// 이 사진이 여러 장 선택 안에 있으면 그 장수(메뉴 문구용)
    var selectionCount = 0
    var showLabels = true
    /// 끌 때 함께 끌 파일들(선택한 사진이면 선택 전체)
    var dragURLs: (() -> [URL])?
    @StateObject private var loader = ThumbLoader()

    var body: some View {
        Color.gray.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = loader.image { Image(nsImage: image).resizable().scaledToFill() }
            }
            .overlay(alignment: .bottomTrailing) {
                if photo.isVideo { tagLabel("영상", .black.opacity(0.6)) }
                else if photo.isRaw { tagLabel("RAW", .black.opacity(0.6)) }
            }
            .overlay(alignment: .topLeading) {
                if showLabels {
                    if photo.source == .estimated { tagLabel("추정", pinColor(.estimated).opacity(0.9)) }
                    else if photo.source == .manual { tagLabel("지정", pinColor(.manual).opacity(0.9)) }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if showLabels { VStack(alignment: .leading, spacing: -6) {
                    if dogLabel == true { tagLabel("🐶 직접", .brown.opacity(0.9)) }
                    if dogLabel == false { tagLabel("강아지 아님", .gray.opacity(0.9)) }
                    if !copies.isEmpty { tagLabel("중복 \(copies.count + 1)", .orange.opacity(0.9)) }
                    if photo.dateFixed { tagLabel("폴더 날짜", .teal.opacity(0.9)) }
                } }
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18)).foregroundStyle(.white, Color.accentColor).padding(4)
                }
            }
            .overlay {
                if isSelected { RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 3) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .help(copies.isEmpty ? photo.relative
                  : photo.relative + "\n\n같은 파일이 \(copies.count)곳 더 있어요:\n"
                    + copies.map(relativePath).joined(separator: "\n"))
            // 클릭과 끌기는 AppKit 뷰가 받는다: SwiftUI의 끌기는 한 장만 되고, 더블클릭 제스처는 한 번 클릭도 늦게 만든다
            .overlay {
                DragClickSource(onClick: { onClick?() },
                                urls: { dragURLs?() ?? [photo.url] },
                                image: { ThumbCache.shared.object(forKey: photo.path as NSString) })
            }
            .contextMenu {
                Button("열기") { NSWorkspace.shared.open(photo.url) }
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
                if photo.isVideo {
                    Button("GIF 만들기…") { GIFJob.shared.load(photo.url); openWindow(id: "gif") }
                }
                if let onShowOnMap, photo.lat != nil {
                    Button("장소 탭에서 위치 보기", action: onShowOnMap)
                }
                if !copies.isEmpty {
                    Button("다른 사본 \(copies.count)개 Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting(copies.map { URL(fileURLWithPath: $0) })
                    }
                }
                if photo.source == .manual, let onUnassign {
                    Divider()
                    Button(unassignTitle, action: onUnassign)
                }
                if let onSetDog, !photo.isVideo {
                    Divider()
                    let suffix = selectionCount > 1 ? " (선택 \(selectionCount)장)" : ""
                    Button("🐶 강아지임" + suffix) { onSetDog(true) }
                    Button("강아지 아님" + suffix) { onSetDog(false) }
                    if dogLabel != nil {
                        Button("직접 구분 지우기 · 자동 분석으로" + suffix) { onSetDog(nil) }
                    }
                }
                if let onTrash {
                    Divider()
                    Button(trashTitle, role: .destructive, action: onTrash)
                }
            }
            .task(id: photo.path) { loader.image = await load() }
    }

    func load() async -> NSImage? {
        if let hit = ThumbCache.shared.object(forKey: photo.path as NSString) { return hit }
        // 빠르게 스크롤해서 금방 지나가는 칸은 만들지 않는다(사라지면 이 대기 중에 취소된다)
        try? await Task.sleep(nanoseconds: 40_000_000)
        if Task.isCancelled { return nil }
        let p = photo
        if let img = await Task.detached(priority: .userInitiated, operation: { ThumbStore.image(for: p) }).value {
            ThumbCache.shared.setObject(img, forKey: photo.path as NSString)
            return img
        }
        // 영상 등은 훑어보기로 만든다
        let req = QLThumbnailGenerator.Request(fileAt: photo.url, size: CGSize(width: 160, height: 160),
                                               scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        ThumbCache.shared.setObject(rep.nsImage, forKey: photo.path as NSString)
        return rep.nsImage
    }
}

/// 드래그할 때만 쓰는 자동 보정본. 임시 폴더에 JPG로 만들고, 앱을 켜고 끌 때 비운다(사진 폴더엔 아무것도 안 생긴다)
final class Enhancer: @unchecked Sendable {
    static let shared = Enhancer()
    static let rawExts: Set<String> = ["cr3", "cr2", "nef", "arw", "raf", "orf", "rw2", "dng"]
    static let imageExts: Set<String> = rawExts.union(["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"])
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("사진지도-보정")
    private let ctx = CIContext()
    private let lock = NSLock()
    private var made: [String: URL] = [:]

    func clear() {
        try? FileManager.default.removeItem(at: dir)
        lock.lock(); made = [:]; lock.unlock()
    }

    /// 켜자마자 첫 드래그가 느리지 않게 그래픽 처리를 미리 한 번 돌려 둔다
    func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            let img = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            var out = img
            for f in img.autoAdjustmentFilters(options: [.redEye: false]) { f.setValue(out, forKey: kCIInputImageKey); out = f.outputImage ?? out }
            _ = self.ctx.createCGImage(out, from: out.extent)
        }
    }

    /// 보정본 파일 주소. 사진이 아니거나(동영상 등) 실패하면 원본을 그대로 돌려준다
    func enhanced(_ url: URL, maxSide: Double) -> URL {
        let ext = url.pathExtension.lowercased()
        guard Self.imageExts.contains(ext) else { return url }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)|\(Int(maxSide))"
        lock.lock(); let cached = made[key]; lock.unlock()
        if let c = cached, FileManager.default.fileExists(atPath: c.path) { return c }

        var img: CIImage
        if Self.rawExts.contains(ext) {
            guard let f = CIRAWFilter(imageURL: url) else { return url }
            let long = max(f.nativeSize.width, f.nativeSize.height)
            if maxSide > 0, long > maxSide { f.scaleFactor = Float(maxSide / long) }
            guard let o = f.outputImage else { return url }
            img = o
        } else {
            guard let o = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return url }
            img = o
            let long = max(img.extent.width, img.extent.height)
            if maxSide > 0, long > maxSide {
                let s = maxSide / long
                img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
            }
        }
        for f in img.autoAdjustmentFilters(options: [.redEye: false]) {
            f.setValue(img, forKey: kCIInputImageKey)
            if let o = f.outputImage { img = o }
        }
        // 같은 이름 사진이 여러 폴더에 있어도 겹치지 않게 드래그마다 하위 폴더를 따로 쓴다(블로그엔 원래 파일 이름으로 올라간다)
        let sub = dir.appendingPathComponent(String(UUID().uuidString.prefix(8)))
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let out = sub.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".jpg")
        // 원본 크기면 원본의 해상도(DPI)를 그대로, 줄였으면 72dpi로 적는다
        var dpi: Double = 72
        if maxSide == 0, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let d = props[kCGImagePropertyDPIWidth] as? Double { dpi = d }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = ctx.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: cs),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return url }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9,
                                              kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return url }
        lock.lock(); made[key] = out; lock.unlock()
        return out
    }

    /// 여러 장이면 동시에 만든다
    func enhanced(_ urls: [URL], maxSide: Double) -> [URL] {
        var out = urls
        let q = DispatchQueue(label: "enhance.collect")
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            let u = enhanced(urls[i], maxSide: maxSide)
            q.sync { out[i] = u }
        }
        return out
    }
}

/// 드래그 시 자동 보정 설정(드래그하는 AppKit 뷰에서 바로 읽는다)
var enhanceOnDrag: Bool = pref("enhanceOnDrag", false)
var enhanceMaxSide: Double = pref("enhanceMaxSide", 0.0)   // 0 = 원본 크기 그대로

/// 썸네일 위에 깔리는 투명한 AppKit 뷰: 클릭은 onClick으로, 끌면 선택한 파일 전체를 Finder·브라우저로 끌어간다
struct DragClickSource: NSViewRepresentable {
    var onClick: () -> Void
    var urls: () -> [URL]
    var image: () -> NSImage?

    func makeNSView(context: Context) -> DragClickView { DragClickView() }
    func updateNSView(_ v: DragClickView, context: Context) {
        v.onClick = onClick; v.urls = urls; v.image = image
    }
}

final class DragClickView: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var urls: (() -> [URL])?
    var image: (() -> NSImage?)?
    private var down: NSEvent?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 우클릭·⌃클릭(메뉴)과 스크롤은 아래 SwiftUI 쪽(우클릭 메뉴, 목록 스크롤)에 넘긴다
        if let e = NSApp.currentEvent {
            switch e.type {
            case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel: return nil
            case .leftMouseDown where e.modifierFlags.contains(.control): return nil
            default: break
            }
        }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { down = e }

    override func mouseDragged(with e: NSEvent) {
        guard let d = down else { return }
        let dx = e.locationInWindow.x - d.locationInWindow.x, dy = e.locationInWindow.y - d.locationInWindow.y
        guard dx * dx + dy * dy > 16 else { return }
        down = nil
        var list = urls?() ?? []
        guard !list.isEmpty else { return }
        if enhanceOnDrag {
            list = Enhancer.shared.enhanced(list, maxSide: enhanceMaxSide)   // 한 장에 0.1~0.3초
        }
        let img = image?() ?? NSWorkspace.shared.icon(forFile: list[0].path)
        let items = list.enumerated().map { i, u -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: u as NSURL)
            let off = CGFloat(min(i, 4)) * 5
            item.setDraggingFrame(bounds.offsetBy(dx: off, dy: -off), contents: i < 5 ? img : nil)
            return item
        }
        beginDraggingSession(with: items, event: e, source: self).draggingFormation = .pile
    }

    override func mouseUp(with e: NSEvent) {
        if down != nil { onClick?() }
        down = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : .copy
    }
}

/// 썸네일 크기(설정)에 맞춘 격자
func gridColumns(_ size: Double) -> [GridItem] { [GridItem(.adaptive(minimum: size), spacing: 4)] }

/// 탭에 맞는 동작을 붙인 썸네일 한 칸
@MainActor
func thumbCell(_ model: Model, _ p: Photo, _ tab: Mode) -> Thumb {
    let sel = model.selection(tab)
    let inSel = sel.contains(p.path)
    let multi = inSel && sel.count > 1
    let manualN = multi ? model.selectedManualCount : 0
    return Thumb(photo: p, isSelected: inSel,
                 onClick: { model.click(p, in: tab) },
                 onUnassign: { manualN > 1 ? model.unassignSelected() : model.unassign(p) },
                 unassignTitle: manualN > 1 ? "선택한 \(manualN)장의 지정 위치 지우기" : "지정한 위치 지우기",
                 onTrash: { model.requestDelete(p, selection: sel) },
                 trashTitle: multi ? "선택한 \(sel.count)장 휴지통으로 이동" : "휴지통으로 이동",
                 copies: model.duplicates[p.path] ?? [],
                 onShowOnMap: tab == .map ? nil : { model.showOnMap(p) },
                 dogLabel: model.dogLabel(p),
                 onSetDog: { model.setDog(p, selection: sel, $0) },
                 selectionCount: inSel ? sel.count : 0,
                 showLabels: model.showLabels,
                 dragURLs: { model.dragURLs(for: p, in: tab) })
}

/// 오래 걸리는 작업의 진행 막대
struct JobBanner: View {
    let job: Model.Job
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView().controlSize(.small)
                Text(job.title).fontWeight(.semibold)
                Spacer()
                if job.canStop {
                    Button("멈추기") { model.stopJob() }.controlSize(.small)
                }
            }
            ProgressView(value: job.fraction)
            HStack {
                Text("\(job.done.formatted()) / \(job.total.formatted())장 · \(Int(job.fraction * 100))%")
                Spacer()
                if let r = job.remaining { Text(r) }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
    }
}

/// 폴더 하나(접기/펼치기) → 그 안의 날짜별 사진
struct FolderSectionView<T: View>: View {
    let sec: FolderSection
    let isOpen: Bool
    let selected: Set<String>
    let columns: [GridItem]
    let toggleOpen: () -> Void
    let toggleAll: ([Photo]) -> Void
    @ViewBuilder let thumb: (Photo) -> T

    var body: some View {
        let picked = sec.photos.reduce(0) { $0 + (selected.contains($1.path) ? 1 : 0) }
        HStack(spacing: 6) {
            Button(action: toggleOpen) {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").frame(width: 12)
                    Image(systemName: "folder.fill").foregroundStyle(.orange)
                    Text(sec.id).fontWeight(.semibold).lineLimit(1).truncationMode(.head)
                    Text("\(sec.photos.count)장\(picked > 0 ? " · 선택 \(picked)" : "")").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sec.id)
            Spacer()
            Button {
                if let p = sec.photos.first { NSWorkspace.shared.open(p.url.deletingLastPathComponent()) }
            } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.plain).help("Finder에서 이 폴더 열기")
            Button("이 폴더 전체") { toggleAll(sec.photos) }.controlSize(.small)
        }
        .padding(.vertical, 3)
        if isOpen {
            ForEach(sec.days) { d in
                HStack {
                    Text("\(d.name) · \(d.photos.count)장").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("이 날 전체") { toggleAll(d.photos) }.controlSize(.mini)
                }
                .padding(.leading, 18)
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(d.photos) { thumb($0) }
                }
                .padding(.leading, 18)
            }
            Divider()
        }
    }
}

// MARK: - 화면

/// 툴바 검색창에서 엔터를 누르면 오른쪽 패널 맨 위에 뜨는 검색 결과
struct SearchResults: View {
    @ObservedObject var model: Model

    var body: some View {
        if !model.results.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.results, id: \.self) { item in
                    Button { model.pick(item) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name ?? "").fontWeight(.medium)
                            Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}

/// 반경 슬라이더 범위. 로그 눈금이라 가까운 거리는 촘촘하게, 먼 거리(시·군 단위)는 성큼성큼 움직인다
let radiusMin = 20.0, radiusMax = 50_000.0

func radiusLabel(_ r: Double) -> String {
    r < 1000 ? "\(Int(r))m" : (r < 10_000 ? String(format: "%.1fkm", r / 1000) : "\(Int(r / 1000))km")
}

struct RadiusRow: View {
    @ObservedObject var model: Model

    var radiusSlider: Binding<Double> {
        Binding(
            get: { log(model.radius / radiusMin) / log(radiusMax / radiusMin) },
            set: { t in
                let r = radiusMin * pow(radiusMax / radiusMin, t)
                // 보기 좋은 값으로 반올림: 1km 미만 10m, 10km 미만 100m, 그 이상 1km 단위
                let step = r < 1000 ? 10.0 : (r < 10_000 ? 100.0 : 1000.0)
                model.radius = (r / step).rounded() * step
            })
    }

    var body: some View {
        HStack {
            Text("반경")
            Slider(value: radiusSlider, in: 0...1)
            Text(radiusLabel(model.radius)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}

/// 필터 아이콘 설명 말풍선. macOS 기본 툴팁(.help)이 이 화면에서 안 떠서 직접 그린다
final class HoverTip: ObservableObject {
    @Published var text: String?
    var owner: String?
}

/// 필터 아이콘 하나. 켜지면 색이 채워지고, 마우스를 올리면 아래에 설명이 나온다
struct FilterIcon: View {
    /// SF Symbols 이름
    let symbol: String
    let tip: String
    @Binding var isOn: Bool
    @ObservedObject var hover: HoverTip
    var disabled = false
    /// 켜져 있는데 확인이 필요할 때(예: 분석 안 된 사진이 빠짐) 오른쪽 위 주황 점
    var warning = false

    var fullTip: String { "\(tip) · " + (disabled ? "지금은 쓸 수 없어요" : (isOn ? "켜짐" : "꺼짐")) }

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(isOn ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if warning { Circle().fill(.orange).frame(width: 8, height: 8).offset(x: 2, y: -2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { inside in
            if inside { hover.text = fullTip; hover.owner = symbol } else if hover.owner == symbol { hover.text = nil; hover.owner = nil }
        }
        // 누른 뒤 켜짐/꺼짐이 바로 바뀌어 보이게
        .onChange(of: isOn) { _, _ in if hover.owner == symbol { hover.text = fullTip } }
    }
}

/// 필터 아이콘 줄: 강아지 | 위치 추정 | RAW | 중복 | 라벨
/// 촬영 기종으로 거르는 버튼(필터 아이콘 줄 오른쪽). 누르면 체크박스 목록이 떠서 여러 기종을 고를 수 있다
struct CameraMenu: View {
    @ObservedObject var model: Model
    @StateObject private var open = Flag()

    var body: some View {
        Button { open.on.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "camera")
                Text(model.cameraFilterLabel)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(model.cameraFilter.isEmpty ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .fixedSize()
        .popover(isPresented: $open.on, arrowEdge: .bottom) { CameraChecklist(model: model) }
    }
}

final class Flag: ObservableObject { @Published var on = false }

struct CameraChecklist: View {
    @ObservedObject var model: Model
    static let phones: Set<String> = ["Galaxy", "iPhone", otherCamera]

    var body: some View {
        let cams = model.cameraCounts.filter { !Self.phones.contains($0.name) && $0.name != Model.noCamera }
        let phones = model.cameraCounts.filter { Self.phones.contains($0.name) }
        let none = model.cameraCounts.filter { $0.name == Model.noCamera }
        VStack(alignment: .leading, spacing: 10) {
            section("카메라", cams)
            section("휴대폰", phones)
            section("", none)
            Divider()
            HStack {
                Button("모두 해제") { model.cameraFilter = [] }.disabled(model.cameraFilter.isEmpty)
                Spacer()
                Text(model.cameraFilter.isEmpty ? "체크하지 않으면 모든 기종" : "\(model.cameraFilter.count)개 기종")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 260)
    }

    @ViewBuilder func section(_ title: String, _ items: [(name: String, count: Int)]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !title.isEmpty { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                ForEach(items, id: \.name) { c in
                    Toggle(isOn: Binding(get: { model.cameraFilter.contains(c.name) },
                                         set: { on in
                                             if on { model.cameraFilter.insert(c.name) } else { model.cameraFilter.remove(c.name) }
                                         })) {
                        HStack {
                            Text(c.name)
                            Spacer(minLength: 16)
                            Text(c.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }
}

struct FilterIcons: View {
    @ObservedObject var model: Model
    @StateObject private var hover = HoverTip()

    var body: some View {
        let needsAnalysis = model.dogOnly && model.unanalyzedCount > 0
        HStack(spacing: 6) {
            FilterIcon(symbol: "dog.fill",
                       tip: needsAnalysis ? "강아지만 보기 (아직 분석 안 된 \(model.unanalyzedCount.formatted())장은 빠져요)"
                                          : "강아지만 보기",
                       isOn: $model.dogOnly, hover: hover, warning: needsAnalysis)
            divider
            FilterIcon(symbol: "clock.arrow.circlepath", tip: "GPS 없는 사진은 촬영 시간으로 위치 추정",
                       isOn: $model.useEstimate, hover: hover)
            if model.mode == .map {
                FilterIcon(symbol: "sparkle.magnifyingglass", tip: "추정한 사진만 보기", isOn: $model.estimatedOnly, hover: hover,
                           disabled: !model.useEstimate)
            }
            divider
            FilterIcon(symbol: "camera.aperture", tip: "RAW(CR3)도 함께 보기", isOn: $model.includeRaw, hover: hover)
            divider
            FilterIcon(symbol: "square.on.square", tip: "중복 사진만 보기", isOn: $model.duplicatesOnly, hover: hover)
            FilterIcon(symbol: "1.square", tip: "중복은 1장만 보기", isOn: $model.oneCopyOnly, hover: hover)
            divider
            FilterIcon(symbol: "tag", tip: "사진 라벨 보기 (추정·지정·직접·중복)", isOn: $model.showLabels, hover: hover)
            divider
            FilterIcon(symbol: "wand.and.stars", tip: "드래그할 때 자동 보정 (원본은 그대로, 보정본은 임시 파일)",
                       isOn: $model.enhanceOnDrag, hover: hover)
            Spacer()
            CameraMenu(model: model)
            if needsAnalysis && !model.analyzing {
                Button("분석하기") { model.toggleAnalysis() }.controlSize(.small)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let t = hover.text {
                Text(t)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .shadow(radius: 3, y: 1)
                    .fixedSize()
                    .offset(y: 30)
                    .allowsHitTesting(false)
            }
        }
    }

    var divider: some View { Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 18).padding(.horizontal, 2) }
}

/// 목록 위 한 줄: 사진 수 + 날짜별/폴더별
struct ListHeader: View {
    @ObservedObject var model: Model
    let tab: Mode

    var byFolder: Binding<Bool> {
        switch tab {
        case .all: return $model.allByFolder
        case .map: return $model.mapByFolder
        case .unlocated: return $model.unlocatedByFolder
        }
    }

    var countText: String {
        let prefix = model.showSelectedOnly ? "선택한 사진만 · " : ""
        switch tab {
        case .all:
            return prefix + "\(model.allCount.formatted())장 · \(model.allDayCount)일 · 폴더 \(model.allFolderCount)개"
        case .map:
            if model.center == nil && !model.showSelectedOnly { return "장소를 골라주세요" }
            return prefix + "\(model.hitCount.formatted())장 · \(model.groups.count)일 · 폴더 \(model.folderSections.count)개"
        case .unlocated:
            return prefix + "위치 없는 사진 \(model.unlocatedCount.formatted())장"
        }
    }

    var body: some View {
        HStack {
            Text(countText).font(.headline).lineLimit(1)
            Spacer()
            if byFolder.wrappedValue {
                Menu {
                    Button("모두 펼치기") { model.expandAllFolders(tab, true) }
                    Button("모두 접기") { model.expandAllFolders(tab, false) }
                } label: { Image(systemName: "rectangle.expand.vertical") }
                    .menuStyle(.borderlessButton).fixedSize().help("폴더 모두 펼치기/접기")
            }
            if tab == .map && model.mapSelected.isEmpty && model.hitCount > 0 {
                Menu {
                    Button("반경 안 \(model.hitCount)장 바로가기로 모으기…") {
                        model.requestCollect(copy: false, items: model.collectTargets())
                    }
                    Button("반경 안 \(model.hitCount)장 복사해서 모으기…") {
                        model.requestCollect(copy: true, items: model.collectTargets())
                    }
                } label: { Image(systemName: "folder.badge.plus") }
                    .menuStyle(.borderlessButton).fixedSize().help("반경 안 사진 전체를 한 폴더로 모아요")
            }
            Picker("", selection: byFolder) {
                Text("날짜별").tag(false)
                Text("폴더별").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
}

/// 사진 목록(날짜별 또는 폴더별). 세 탭이 함께 쓴다
struct PhotoList: View {
    @ObservedObject var model: Model
    let tab: Mode

    var byFolder: Bool {
        switch tab { case .all: return model.allByFolder; case .map: return model.mapByFolder; case .unlocated: return model.unlocatedByFolder }
    }
    var days: [DayGroup] {
        switch tab { case .all: return model.allGroups; case .map: return model.groups; case .unlocated: return model.unlocatedGroups }
    }
    var folders: [FolderSection] {
        switch tab { case .all: return model.allFolders; case .map: return model.folderSections; case .unlocated: return model.unlocatedFolders }
    }

    var body: some View {
        let cols = gridColumns(model.thumbSize)
        let sel = model.selection(tab)
        ScrollViewReader { proxy in
        ScrollView {
            if tab == .map && model.center == nil && !model.showSelectedOnly {
                Text("위에서 장소를 검색하거나, 지도의 핀이나 아무 곳을 클릭하면 그 주변 사진이 여기에 나와요.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 40).multilineTextAlignment(.center)
            } else if byFolder {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(folders) { sec in
                        FolderSectionView(sec: sec, isOpen: model.isFolderOpen(tab, sec.id), selected: sel, columns: cols,
                                          toggleOpen: { model.toggleFolderOpen(tab, sec.id) },
                                          toggleAll: { model.toggleGroup($0, in: tab) }) { thumbCell(model, $0, tab).id($0.path) }
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(days) { g in
                        HStack {
                            Text(g.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button("이 날 전체") { model.toggleGroup(g.photos, in: tab) }.controlSize(.small)
                        }
                        LazyVGrid(columns: cols, spacing: 4) {
                            ForEach(g.photos) { thumbCell(model, $0, tab).id($0.path) }
                        }
                    }
                }
            }
        }
        // 화살표 키로 움직이면 그 칸이 보이게 스크롤
        .onChange(of: model.cursor) { _, c in
            if let c { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(c) } }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { updateColumns(g.size.width) }
                .onChange(of: g.size.width) { _, w in updateColumns(w) }
                .onChange(of: model.thumbSize) { _, _ in updateColumns(g.size.width) }
        })
        }
    }

    /// 격자 한 줄에 들어가는 칸 수(위아래 화살표 이동용)
    func updateColumns(_ width: CGFloat) {
        let size = model.thumbSize, spacing = 4.0
        model.gridColumnCount = max(1, Int((Double(width) - 8 + spacing) / (size + spacing)))
    }
}

/// 사진을 골랐을 때만 목록 아래에 뜨는 작업 막대
struct ActionBar: View {
    @ObservedObject var model: Model

    var body: some View {
        let tab = model.mode
        let sel = model.selection(tab)
        let hidden = model.hiddenSelectedCount(tab)
        let est = model.estimatedCount(in: sel)
        let manualN = model.selectedManualCount
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("선택 \(sel.count.formatted())장").fontWeight(.semibold)
                if hidden > 0 {
                    Text("· 화면 밖 \(hidden.formatted())장").foregroundStyle(.orange)
                        .help("장소를 옮겼거나 필터 때문에 지금 목록에는 안 보이는 선택이에요. 복사·삭제에 함께 들어가요")
                }
                Spacer()
                Toggle("선택한 것만 보기", isOn: $model.showSelectedOnly).toggleStyle(.button)
                Button("해제") { model.clearSelection() }.help("선택 해제 (Esc)")
            }
            HStack(spacing: 8) {
                if tab == .unlocated {
                    Button("원 위치로 지정 (\(sel.count)장)") { model.assignCurrentSelection() }
                        .buttonStyle(.borderedProminent).tint(pinColor(.manual))
                        .disabled(model.center == nil)
                        .help(model.center == nil ? "위에서 장소를 검색하거나 지도를 클릭해 위치를 먼저 골라주세요"
                              : "선택한 사진을 지도의 빨간 원 중심 위치로 지정해요")
                } else {
                    Menu {
                        if est > 0 {
                            Button("추정 위치 맞음 · 확정 (\(est)장)") { model.confirmEstimated(sel) }
                        }
                        Button(model.center == nil ? "원 위치로 지정 (먼저 장소를 고르세요)" : "원 위치로 지정 (\(sel.count)장)") {
                            model.assignCurrentSelection()
                        }
                        .disabled(model.center == nil)
                        if manualN > 0 {
                            Button("지정 위치 지우기 (\(manualN)장)") { model.unassignSelected() }
                        }
                    } label: { Label("위치", systemImage: "mappin.and.ellipse") }
                        .fixedSize()
                }
                Menu {
                    Button("바로가기로 모으기…") { model.requestCollect(copy: false, items: model.collectTargets()) }
                    Button("복사해서 모으기…") { model.requestCollect(copy: true, items: model.collectTargets()) }
                } label: { Label("모으기", systemImage: "folder.badge.plus") }
                    .fixedSize()
                Menu {
                    Button("🐶 강아지임") { model.setDogForSelection(true) }
                    Button("강아지 아님") { model.setDogForSelection(false) }
                    Button("직접 구분 지우기 · 자동 분석으로") { model.setDogForSelection(nil) }
                } label: { Label("강아지", systemImage: "pawprint") }
                    .fixedSize()
                Spacer()
                Button(role: .destructive) { model.requestDelete(selection: sel) } label: {
                    Image(systemName: "trash")
                }
                .help("휴지통으로 이동 (Delete)")
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
    }
}

/// 아래쪽 한 줄: 사진 통계 + 썸네일 크기
struct StatsBar: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack(spacing: 6) {
            Text(model.stats).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .help("스페이스: 미리보기 · ⌘클릭: 여러 장 · ⇧클릭: 범위 · ⌘A: 모두 선택 · Delete: 휴지통 · ⌘Z: 되돌리기")
            Spacer()
            Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(.secondary)
            Slider(value: $model.thumbSize, in: 64...200).frame(width: 90).controlSize(.mini)
                .help("썸네일 크기 (⌘+ / ⌘-)")
            Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }
}

struct Sidebar: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job = model.job { JobBanner(job: job, model: model) }
            SearchResults(model: model)
            switch model.mode {
            case .map:
                RadiusRow(model: model)
            case .all:
                HStack {
                    TextField("폴더·파일 이름으로 거르기", text: $model.allFilter).textFieldStyle(.roundedBorder)
                    Picker("", selection: $model.allLocFilter) {
                        ForEach(LocFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("위치 있는 사진 / 추정 사진 / 위치 없는 사진만 보기")
                }
            case .unlocated:
                TextField("폴더·파일 이름으로 거르기 (예: 260502_도남)", text: $model.unlocatedFilter)
                    .textFieldStyle(.roundedBorder)
            }
            FilterIcons(model: model).zIndex(1)
            Divider()
            ListHeader(model: model, tab: model.mode)
            PhotoList(model: model, tab: model.mode)
            if !model.currentSelection.isEmpty { ActionBar(model: model) }
            StatsBar(model: model)
        }
        .controlSize(.small)
        .padding(12)
    }
}

/// '작업' 메뉴 항목. 메뉴 막대와 툴바 버튼이 함께 쓴다
struct WorkMenuItems: View {
    @ObservedObject var model: Model
    var shortcuts = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("다시 읽기 (새 사진 반영)") { model.rescan() }
            .keyboardShortcut(shortcuts ? KeyboardShortcut("r", modifiers: .command) : nil)
        Divider()
        Button(model.analyzing ? "🐾 사진 분석 멈추기"
               : (model.unanalyzedCount > 0 ? "🐾 사진 분석 (\(model.unanalyzedCount.formatted())장 남음)" : "🐾 사진 분석 (모두 끝남)")) {
            model.toggleAnalysis()
        }
        .disabled(!model.analyzing && model.unanalyzedCount == 0)
        Button(model.uncheckedDuplicates > 0 ? "📄 중복 검사 (\(model.uncheckedDuplicates.formatted())개 확인 필요)" : "📄 중복 검사") {
            model.checkDuplicates()
        }
        .disabled(model.checkingDuplicates)
        Divider()
        Button("사진 폴더 관리…") { openSettings() }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        HSplitView {
            MapView(model: model).frame(minWidth: 400)
                .overlay(alignment: .topLeading) {
                    // 핀 숫자가 어떤 필터 기준인지 지도 위에 알려준다
                    if let label = model.pinFilterLabel {
                        Label("지도 숫자: \(label)", systemImage: "line.3.horizontal.decrease.circle.fill")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(10)
                    }
                }
                .overlay(alignment: .bottomLeading) { PinLegend().padding(10) }
            Sidebar(model: model).frame(minWidth: 420, idealWidth: 500)
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .overlay { if model.roots.isEmpty { WelcomeView(model: model) } }
        .onAppear {
            KeyMonitor.install(model)
            // 창이 뜬 뒤: 검색창에 커서가 먼저 들어가 스페이스·⌘A를 가로채지 않게 비우고, 지도|목록 경계 위치를 기억하게 한다
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let w = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
                w.makeFirstResponder(nil)
                if let split = findSplitView(w.contentView) { split.autosaveName = "PhotoMapSplit" }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $model.mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("⌘1 전체 · ⌘2 장소 · ⌘3 위치 없음")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    WorkMenuItems(model: model)
                } label: {
                    Label("작업", systemImage: (model.unanalyzedCount > 0 || model.uncheckedDuplicates > 0)
                          ? "ellipsis.circle.fill" : "ellipsis.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help("다시 읽기 · 사진 분석 · 중복 검사")
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "장소 검색 (예: 도기온)")
        .onSubmit(of: .search) { model.search() }
        .alert(deleteTitle, isPresented: Binding(get: { model.pendingDelete != nil },
                                                 set: { if !$0 { model.pendingDelete = nil } })) {
            let pairCount = model.pairs(of: model.deletePlan(includePairs: false).delete).count
            Button("휴지통으로 이동", role: .destructive) { model.performDelete(includePairs: false) }
            if pairCount > 0 {
                Button("짝 파일(RAW·JPG) \(pairCount)장까지 함께 이동", role: .destructive) {
                    model.performDelete(includePairs: true)
                }
            }
            Button("취소", role: .cancel) { model.pendingDelete = nil }
        } message: {
            let plan = model.deletePlan(includePairs: false)
            let pairCount = model.pairs(of: plan.delete).count
            Text("휴지통에서 되살리거나 ⌘Z로 되돌릴 수 있어요."
                 + (plan.kept.isEmpty ? ""
                    : "\n\n같은 파일의 사본을 전부 선택한 묶음이 \(plan.kept.count)개 있어요. 사진이 없어지지 않게 묶음마다 1장씩 남겨요:\n"
                      + plan.kept.prefix(5).map(\.relative).joined(separator: "\n")
                      + (plan.kept.count > 5 ? "\n외 \(plan.kept.count - 5)장" : ""))
                 + (pairCount > 0 ? "\n\n같은 이름의 짝 파일(RAW·JPG 등)이 \(pairCount)장 더 있어요." : ""))
        }
        .alert("모음 폴더 이름", isPresented: Binding(get: { model.collectRequest != nil },
                                                  set: { if !$0 { model.collectRequest = nil } })) {
            TextField("폴더 이름", text: $model.folderName)
            Button(model.collectRequest?.copy == true ? "복사해서 모으기" : "바로가기로 모으기") {
                if let r = model.collectRequest { model.collect(copy: r.copy, items: r.items) }
                model.collectRequest = nil
            }
            Button("취소", role: .cancel) { model.collectRequest = nil }
        } message: {
            let r = model.collectRequest
            Text("\(r?.items.count ?? 0)장을 \(collectRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))/ 아래 이 이름의 폴더에 "
                 + (r?.copy == true ? "복사해요." : "바로가기로 모아요. 원본은 그대로예요."))
        }
    }

    var deleteTitle: String {
        "\(model.deletePlan(includePairs: false).delete.count)장을 휴지통으로 옮길까요?"
    }
}

/// HSplitView 안쪽의 NSSplitView 찾기(경계선 위치 기억용)
func findSplitView(_ v: NSView?) -> NSSplitView? {
    guard let v else { return nil }
    if let s = v as? NSSplitView { return s }
    for sub in v.subviews { if let s = findSplitView(sub) { return s } }
    return nil
}

/// ⌘F: 툴바 검색창으로
@MainActor func focusSearch() {
    for w in NSApp.windows where w.isVisible {
        if let item = w.toolbar?.items.first(where: { $0 is NSSearchToolbarItem }) as? NSSearchToolbarItem {
            w.makeKeyAndOrderFront(nil)
            item.beginSearchInteraction()
            return
        }
    }
}

/// 지도 왼쪽 아래 핀 색 설명
struct PinLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach([LocSource.gps, .estimated, .manual], id: \.self) { k in
                HStack(spacing: 4) {
                    Circle().fill(pinColor(k)).frame(width: 9, height: 9)
                    Text(k == .gps ? "GPS" : (k == .estimated ? "추정" : "지정"))
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}

// MARK: - 키보드 · 미리보기

/// 글자를 입력하는 칸에 커서가 있는지
@MainActor func isEditingText() -> Bool { NSApp.keyWindow?.firstResponder is NSText }

/// 스페이스(미리보기) · Esc(선택 해제) · Delete(휴지통) · ⌘A(모두 선택).
/// 글자 입력 중이거나 확인 창이 떠 있을 때는 건드리지 않는다
enum KeyMonitor {
    private static var installed = false

    @MainActor static func install(_ model: Model) {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if isEditingText() { return e }
            let inPreview = NSApp.keyWindow is QLPreviewPanel
            // 확인 창·시트가 떠 있으면(주 창이 아닌 창이 앞에 있으면) 그 창에 맡긴다
            if !inPreview && NSApp.keyWindow !== NSApp.mainWindow { return e }
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch e.keyCode {
            case 49 where flags.isEmpty:                       // 스페이스
                Preview.toggle(model); return nil
            case 53:                                           // Esc
                if Preview.isOpen { Preview.close(); return nil }
                if !model.currentSelection.isEmpty { model.clearSelection(); return nil }
                return e
            case 51, 117:                                      // Delete, ⌦
                if inPreview || model.currentSelection.isEmpty { return e }
                model.requestDelete(selection: model.currentSelection); return nil
            case 0 where flags == .command:                    // ⌘A
                if inPreview { return e }
                model.selectAllVisible(); return nil
            case 123, 124, 125, 126:                           // ← → ↓ ↑
                if inPreview { return e }                      // 미리보기 창에서는 사진 넘기기
                let cols = model.gridColumnCount
                let step = [123: -1, 124: 1, 125: cols, 126: -cols][Int(e.keyCode)]!
                model.moveCursor(step, extend: flags.contains(.shift)); return nil
            case 36, 76 where flags.isEmpty:                   // 엔터: 열기
                if inPreview || model.currentSelection.isEmpty { return e }
                model.openSelection(); return nil
            default:
                return e
            }
        }
    }
}

/// Finder처럼 스페이스바로 크게 보는 훑어보기 창
final class Preview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = Preview()
    var urls: [URL] = []

    static var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    @MainActor static func toggle(_ model: Model) {
        if isOpen { close(); return }
        let items = model.previewItems()
        guard !items.urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        shared.urls = items.urls
        panel.dataSource = shared
        panel.delegate = shared
        panel.reloadData()
        panel.currentPreviewItemIndex = items.start
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() { QLPreviewPanel.shared()?.orderOut(nil) }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}

/// 훑어보기 창이 응답 체인에서 주인을 찾을 때 앱이 맡는다고 알려준다
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        Enhancer.shared.clear()
        try? FileManager.default.removeItem(at: GIFJob.dir)
        if enhanceOnDrag { Enhancer.shared.warmUp() }
    }
    func applicationWillTerminate(_ n: Notification) { Enhancer.shared.clear(); try? FileManager.default.removeItem(at: GIFJob.dir) }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = Preview.shared
        panel.delegate = Preview.shared
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

// MARK: - GIF 만들기 (동영상 → 용량 제한에 맞춰 여러 장으로 나눈 GIF)

enum GIFEncoder {
    /// 여러 장면을 하나의 움직이는 GIF로
    static func data(_ frames: [CGImage], delay: Double) -> Data? {
        let data = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                          kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        for f in frames { CGImageDestinationAddImage(d, f, frameProps) }
        guard CGImageDestinationFinalize(d) else { return nil }
        return data as Data
    }

    /// 용량 제한(바이트)을 넘지 않게 장면을 앞에서부터 묶어 여러 GIF로 나눈다.
    /// 장면 하나씩 GIF로 만들어 본 크기를 더해 어림하고, 실제로 만든 뒤 넘치면 뒤쪽 장면을 다음 장으로 넘긴다
    static func split(_ frames: [CGImage], delay: Double, limit: Int,
                      progress: (Double) -> Void) -> [(data: Data, first: Int, count: Int)] {
        let sizes = frames.enumerated().map { i, f -> Int in
            if i % 10 == 0 { progress(0.5 * Double(i) / Double(frames.count)) }
            return data([f], delay: delay)?.count ?? 0
        }
        var parts: [(Data, Int, Int)] = []
        var start = 0
        while start < frames.count {
            var end = start, acc = 0
            while end < frames.count, end == start || acc + sizes[end] <= Int(Double(limit) * 0.97) {
                acc += sizes[end]; end += 1
            }
            var out = data(Array(frames[start..<end]), delay: delay)
            while let o = out, o.count > limit, end - start > 1 {
                end = start + max(1, Int(Double(end - start) * 0.9))
                out = data(Array(frames[start..<end]), delay: delay)
            }
            if let o = out { parts.append((o, start, end - start)) }
            start = end
            progress(0.5 + 0.5 * Double(start) / Double(frames.count))
        }
        return parts
    }
}

@MainActor
final class GIFJob: ObservableObject {
    static let shared = GIFJob()
    /// 만든 GIF는 임시 폴더에 둔다(앱을 켜고 끌 때 비운다). 블로그로 끌어 넣거나 '다운로드에 저장'으로 남긴다
    nonisolated static let dir = FileManager.default.temporaryDirectory.appendingPathComponent("사진지도-GIF")

    struct Part: Identifiable {
        let id = UUID()
        let url: URL
        let bytes: Int
        let from: Double
        let to: Double
    }

    @Published var source: URL?
    @Published var duration: Double = 0
    @Published var start: Double = 0
    @Published var length: Double = 10
    @Published var longSide: Int = pref("gifLongSide", 480) { didSet { prefs.set(longSide, forKey: "gifLongSide") } }
    @Published var fps: Int = pref("gifFPS", 10) { didSet { prefs.set(fps, forKey: "gifFPS") } }
    @Published var limitMB: Double = pref("gifLimitMB", 10.0) { didSet { prefs.set(limitMB, forKey: "gifLimitMB") } }
    @Published var working = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var parts: [Part] = []
    private var task: Task<Void, Never>?

    /// 장면이 너무 많으면 메모리가 커지므로 한 번에 만드는 길이를 제한한다
    var maxLength: Double { 900.0 / Double(fps) }

    func load(_ url: URL) {
        task?.cancel()
        source = url; parts = []; status = ""; working = false; progress = 0
        start = 0; duration = 0
        Task {
            let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            guard source == url else { return }
            duration = d.isFinite ? d : 0
            length = min(duration, 10)
        }
    }

    func cancel() { task?.cancel() }

    func make() {
        guard let url = source, duration > 0 else { return }
        let from = max(0, min(start, duration)), to = min(duration, from + min(length, maxLength))
        guard to > from else { return }
        let fps = Double(self.fps), side = CGFloat(longSide), limit = Int(limitMB * 1_000_000)
        working = true; progress = 0; parts = []; status = "장면 뽑는 중…"
        task = Task.detached(priority: .userInitiated) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: side, height: side)
            let tol = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
            gen.requestedTimeToleranceBefore = tol
            gen.requestedTimeToleranceAfter = tol
            let times = stride(from: from, to: to, by: 1 / fps).map { CMTime(seconds: $0, preferredTimescale: 600) }
            var frames: [CGImage] = []
            for await r in gen.images(for: times) {
                if Task.isCancelled { break }
                if let img = try? r.image { frames.append(img) }
                let n = frames.count
                if n % 10 == 0 { await MainActor.run { self.progress = 0.4 * Double(n) / Double(times.count) } }
            }
            if Task.isCancelled || frames.isEmpty {
                await MainActor.run { self.working = false; self.status = frames.isEmpty ? "장면을 읽지 못했어요" : "멈췄어요" }
                return
            }
            await MainActor.run { self.status = "GIF 만드는 중…" }
            let made = GIFEncoder.split(frames, delay: 1 / fps, limit: limit) { f in
                Task { @MainActor in self.progress = 0.4 + 0.6 * f }
            }
            let sub = GIFJob.dir.appendingPathComponent(String(UUID().uuidString.prefix(8)))
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let base = url.deletingPathExtension().lastPathComponent
            var out: [Part] = []
            for (i, p) in made.enumerated() {
                let name = made.count == 1 ? "\(base).gif" : "\(base)_\(i + 1).gif"
                let file = sub.appendingPathComponent(name)
                guard (try? p.data.write(to: file)) != nil else { continue }
                out.append(Part(url: file, bytes: p.data.count,
                                from: from + Double(p.first) / fps, to: from + Double(p.first + p.count) / fps))
            }
            await MainActor.run {
                self.parts = out; self.working = false; self.progress = 1
                self.status = out.count > 1
                    ? "\(String(format: "%.0f", self.limitMB))MB를 넘지 않게 \(out.count)장으로 나눴어요"
                    : "다 만들었어요"
            }
        }
    }

    func saveToDownloads() {
        let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var saved: [URL] = []
        for p in parts {
            var dest = dl.appendingPathComponent(p.url.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = dl.appendingPathComponent(p.url.deletingPathExtension().lastPathComponent + " \(n).gif"); n += 1
            }
            if (try? FileManager.default.copyItem(at: p.url, to: dest)) != nil { saved.append(dest) }
        }
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
    }
}

/// 움직이는 GIF 미리보기
struct AnimatedImage: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.animates = true
        v.imageScaling = .scaleProportionallyDown
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {
        if v.image == nil || (v.toolTip ?? "") != url.path {
            v.image = NSImage(contentsOf: url)
            v.toolTip = url.path
        }
    }
}

struct GIFView: View {
    @ObservedObject var job: GIFJob
    @StateObject private var preview = GIFPreviewPick()

    func sec(_ v: Double) -> String { String(format: "%.1f초", v) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let src = job.source {
                Label(src.lastPathComponent, systemImage: "film").font(.headline)
                Form {
                    LabeledContent("영상 길이", value: job.duration > 0 ? sec(job.duration) : "읽는 중…")
                    LabeledContent("시작") {
                        HStack {
                            Slider(value: $job.start, in: 0...max(job.duration, 0.1))
                            Text(sec(job.start)).monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                    LabeledContent("길이") {
                        HStack {
                            Slider(value: $job.length, in: 0.5...max(min(job.maxLength, job.duration), 0.6))
                            Text(sec(min(job.length, max(0, job.duration - job.start))))
                                .monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                    Picker("크기 (긴 변)", selection: $job.longSide) {
                        ForEach([320, 480, 640, 800], id: \.self) { Text("\($0)px").tag($0) }
                    }
                    Picker("부드러움", selection: $job.fps) {
                        Text("초당 8장 (가벼움)").tag(8)
                        Text("초당 10장").tag(10)
                        Text("초당 15장").tag(15)
                        Text("초당 20장 (부드러움)").tag(20)
                    }
                    Picker("한 장 최대 용량", selection: $job.limitMB) {
                        ForEach([5.0, 10.0, 15.0, 20.0], id: \.self) { Text("\(Int($0))MB").tag($0) }
                    }
                }
                .formStyle(.grouped)
                .disabled(job.working)

                HStack {
                    if job.working {
                        ProgressView(value: job.progress).frame(maxWidth: .infinity)
                        Button("멈추기") { job.cancel() }
                    } else {
                        Text(job.status).foregroundStyle(.secondary)
                        Spacer()
                        Button("GIF 만들기") { job.make() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(job.duration == 0)
                    }
                }

                if !job.parts.isEmpty {
                    Divider()
                    let shown = job.parts.first { $0.id == preview.id } ?? job.parts[0]
                    AnimatedImage(url: shown.url)
                        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 240)
                    Text("아래 GIF를 블로그로 바로 끌어다 넣을 수 있어요").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(Array(job.parts.enumerated()), id: \.element.id) { i, p in
                                HStack {
                                    Image(systemName: "photo.on.rectangle").foregroundStyle(.tint)
                                    Text(job.parts.count > 1 ? "\(i + 1)번" : "GIF").fontWeight(.medium)
                                    Text("\(sec(p.from)) ~ \(sec(p.to))").foregroundStyle(.secondary).monospacedDigit()
                                    Spacer()
                                    Text(String(format: "%.1fMB", Double(p.bytes) / 1_000_000)).monospacedDigit()
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(p.id == shown.id ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .overlay {
                                    DragClickSource(onClick: { preview.id = p.id }, urls: { [p.url] },
                                                    image: { NSImage(contentsOf: p.url) })
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    HStack {
                        Spacer()
                        Button("다운로드 폴더에 저장") { job.saveToDownloads() }
                    }
                }
            } else {
                Text("사진 목록에서 동영상을 우클릭 → GIF 만들기…를 고르세요")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

final class GIFPreviewPick: ObservableObject { @Published var id: UUID? }

// MARK: - 설정 창 (⌘,)

struct SettingsView: View {
    @ObservedObject var model: Model

    var body: some View {
        TabView {
            Form {
                Section("사진을 읽어 올 폴더 (하위 폴더 포함)") { RootsList(model: model) }
                Text("폴더를 빼도 사진 파일은 그대로예요. 외장 디스크는 연결돼 있을 때만 보여요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("사진 폴더", systemImage: "folder") }

            Form {
                Section("위치 추정") {
                    Toggle("GPS 없는 사진은 촬영 시간으로 위치 추정", isOn: $model.useEstimate)
                    Picker("추정 시간 범위", selection: $model.estimateMinutes) {
                        ForEach([10, 20, 30, 60, 120, 180], id: \.self) { m in
                            Text(m < 60 ? "앞뒤 \(m)분" : "앞뒤 \(m / 60)시간").tag(m)
                        }
                    }
                    .disabled(!model.useEstimate)
                    Text("이 시간 안에 찍힌 GPS 사진이 있으면 그 위치를 빌려 써요. 넓힐수록 많이 채워지지만 틀릴 가능성도 커져요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("촬영 날짜") {
                    Toggle("촬영 시각이 없거나 믿기 어려우면 폴더 이름의 날짜 쓰기", isOn: $model.useFolderDates)
                    Text("폴더 이름이 190128_코타키나발루처럼 날짜로 시작할 때, 사진 날짜가 없거나 폴더 날짜보다 45일 넘게 뒤면(내보내거나 복사한 날) 폴더 날짜로 보여줘요. 이런 사진은 시간으로 위치를 추정하지 않아요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("중복") {
                    Toggle("중복 기준: 파일 이름까지 같아야 중복", isOn: $model.sameNameOnly)
                    Text("끄면 이름을 바꿔 저장한 사본(예: 네이버클라우드 백업)도 중복으로 봐요. 내용은 항상 파일 전체를 비교해요.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(model.uncheckedDuplicates > 0 ? "중복 검사 (\(model.uncheckedDuplicates)개 확인 필요)" : "중복 다시 검사") {
                        model.checkDuplicates()
                    }
                    .disabled(model.checkingDuplicates)
                }
            }
            .tabItem { Label("위치·중복", systemImage: "mappin.and.ellipse") }

            Form {
                Section("썸네일") {
                    LabeledContent("크기") {
                        Slider(value: $model.thumbSize, in: 64...200) { Text("크기") }
                            .labelsHidden().frame(width: 200)
                    }
                    Toggle("사진 라벨 보기 (추정·지정·직접·중복)", isOn: $model.showLabels)
                }
                Section {
                    Toggle("드래그할 때 자동 보정", isOn: $model.enhanceOnDrag)
                    Picker("크기", selection: $model.enhanceMaxSide) {
                        Text("원본 크기 (보정만)").tag(0.0)
                        Text("긴 변 3000px").tag(3000.0)
                        Text("긴 변 2000px").tag(2000.0)
                        Text("긴 변 1600px").tag(1600.0)
                    }
                    .disabled(!model.enhanceOnDrag)
                } header: { Text("드래그 보정") } footer: {
                    Text("블로그·Finder로 끌어갈 때 밝기·대비·색을 자동으로 맞춘 JPG를 넘겨요. RAW(CR3)도 JPG로 바뀌어요. 원본은 바꾸지 않고, 보정본은 임시 파일이라 앱을 끄면 지워져요. 위치(GPS) 정보는 빠져요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("저장한 썸네일") {
                    LabeledContent("용량", value: model.thumbBytes.map { "\($0 / 1_048_576)MB" } ?? "계산 중…")
                    HStack {
                        Button("전체 만들기") { model.buildAllThumbs() }.disabled(model.buildingThumbs || model.analyzing)
                        Button("비우기") { model.clearThumbs(); model.refreshThumbBytes() }.disabled(model.buildingThumbs)
                    }
                }
            }
            .tabItem { Label("보기", systemImage: "photo.on.rectangle") }
            .onAppear { model.refreshThumbBytes() }

            Form {
                Section("강아지 찾기") {
                    LabeledContent("분석한 사진", value: "\(model.analyzedCount.formatted()) / \(model.totalCount.formatted())장")
                    Button(model.analyzing ? "분석 멈추기" : "남은 사진 분석하기") { model.toggleAnalysis() }
                        .disabled(!model.analyzing && model.unanalyzedCount == 0)
                    Text("맥 안에서만 분석해요(인터넷으로 보내지 않아요). 틀린 사진은 우클릭 → '강아지임/강아지 아님'으로 바로잡으면 분석보다 우선해요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("분석", systemImage: "pawprint") }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 400)
    }
}

/// 사진 폴더 목록(설정 창)
struct RootsList: View {
    @ObservedObject var model: Model

    var body: some View {
        ForEach(Array(model.roots.enumerated()), id: \.element.path) { i, u in
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(u.lastPathComponent + (i == 0 ? "  (기본)" : "")).fontWeight(.medium)
                    Text(u.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Finder") { NSWorkspace.shared.open(u) }
                Button("빼기", role: .destructive) { model.removeRoot(u) }
            }
        }
        Button("폴더 추가…") { model.addRoots() }
    }
}

/// 처음 켰을 때(사진 폴더가 하나도 없을 때) 보여주는 안내
struct WelcomeView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "map.fill").font(.system(size: 52)).foregroundStyle(.tint)
            Text("사진지도에 오신 걸 환영해요").font(.title.weight(.semibold))
            Text("사진이 들어 있는 폴더를 고르면, 사진의 GPS 위치를 읽어 지도에 보여줘요.\n사진 파일은 바꾸지 않고, 위치 지정은 이 앱 안에만 저장돼요.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { model.addRoots() } label: {
                Label("사진 폴더 선택…", systemImage: "folder.badge.plus").padding(.horizontal, 8)
            }
            .controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            Text("여러 폴더를 한꺼번에 고를 수 있고, 나중에 설정(⌘,)에서 더하거나 뺄 수 있어요.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - 사진 정보 창 (⌘I)

/// 정보 창에 보여줄 큰 썸네일과 카메라 정보
final class InfoLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var camera: [(String, String)] = []
}

func cameraInfo(_ url: URL) -> [(String, String)] {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
    else { return [] }
    let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    var out: [(String, String)] = []
    if let m = tiff[kCGImagePropertyTIFFModel] as? String { out.append(("카메라", m)) }
    if let l = exif[kCGImagePropertyExifLensModel] as? String { out.append(("렌즈", l)) }
    var shot: [String] = []
    if let f = exif[kCGImagePropertyExifFNumber] as? Double { shot.append(String(format: "f/%.1f", f)) }
    if let t = exif[kCGImagePropertyExifExposureTime] as? Double { shot.append(t < 1 ? "1/\(Int((1 / t).rounded()))초" : String(format: "%.1f초", t)) }
    if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { shot.append("ISO \(iso)") }
    if !shot.isEmpty { out.append(("촬영 설정", shot.joined(separator: " · "))) }
    if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int { out.append(("해상도", "\(w) × \(h)")) }
    return out
}

let infoDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.dateFormat = "yyyy년 M월 d일 (E) a h:mm:ss"
    return f
}()

struct InfoView: View {
    @ObservedObject var model: Model
    @StateObject private var loader = InfoLoader()

    var body: some View {
        Group {
            let count = model.currentSelection.count
            if count > 1 {
                summary
            } else if let p = model.infoPhoto {
                detail(p)
            } else {
                Text("사진을 고르면 정보가 여기에 나와요.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 340)
        .frame(minHeight: 200)
    }

    var summary: some View {
        let s = model.selectionSummary()
        return Form {
            Section("선택 \(s.count.formatted())장") {
                LabeledContent("GPS", value: "\(s.gps)장")
                LabeledContent("추정", value: "\(s.est)장")
                LabeledContent("지정", value: "\(s.manual)장")
                LabeledContent("위치 없음", value: "\(s.none)장")
                LabeledContent("강아지", value: "\(s.dogs)장")
                if let a = s.from, let b = s.to {
                    LabeledContent("기간", value: "\(dayTitleFormatter.string(from: a)) ~ \(dayTitleFormatter.string(from: b))")
                }
            }
        }
        .formStyle(.grouped)
    }

    func detail(_ p: Photo) -> some View {
        Form {
            Section {
                Group {
                    if let img = loader.image {
                        Image(nsImage: img).resizable().scaledToFit()
                    } else {
                        Color.gray.opacity(0.15)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Section("파일") {
                LabeledContent("이름", value: p.url.lastPathComponent)
                LabeledContent("폴더") {
                    Button(p.parentFolder) { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
                        .buttonStyle(.link).lineLimit(1).truncationMode(.head)
                }
                if let fd = p.folderDate {
                    LabeledContent("촬영") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(dayTitleFormatter.string(from: fd) + " (폴더 이름 날짜)")
                            Text(p.date.map { "파일 날짜 " + dayTitleFormatter.string(from: $0) + "는 내보내거나 복사한 날로 보여요" }
                                 ?? "파일에 촬영 시각이 없어요")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }
                    }
                } else if let d = p.date {
                    LabeledContent("촬영", value: infoDateFormatter.string(from: d))
                }
                if let size = p.size { LabeledContent("크기", value: String(format: "%.1fMB", Double(size) / 1_048_576)) }
                ForEach(loader.camera, id: \.0) { k, v in LabeledContent(k, value: v) }
            }
            Section("위치") {
                LabeledContent("출처") {
                    HStack(spacing: 4) {
                        if let src = p.source { Circle().fill(pinColor(src)).frame(width: 8, height: 8) }
                        Text(p.source == .gps ? "GPS (사진에 기록됨)" : p.source == .estimated ? "추정 (촬영 시간 기준)"
                             : p.source == .manual ? "직접 지정" : "위치 없음")
                    }
                }
                if p.source == .estimated, let ref = model.estimateRef[p.path] {
                    let min = Int((abs(ref.dt) / 60).rounded())
                    LabeledContent("추정 근거") {
                        Text("\((ref.path as NSString).lastPathComponent) · \(min == 0 ? "1분 안쪽" : "\(min)분") \(ref.dt >= 0 ? "전에" : "뒤에") 찍힌 GPS 사진")
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let lat = p.lat, let lon = p.lon {
                    LabeledContent("좌표", value: String(format: "%.5f, %.5f", lat, lon))
                    if model.mode != .map { Button("장소 탭에서 보기") { model.showOnMap(p) } }
                }
            }
            Section("기타") {
                let label = model.dogLabel(p)
                LabeledContent("강아지", value: label != nil ? (label! ? "강아지임 (직접)" : "강아지 아님 (직접)")
                                : (p.dog == nil ? "아직 분석 안 함" : (p.dog! ? "있음 (자동 분석)" : "없음 (자동 분석)")))
                let copies = model.duplicates[p.path] ?? []
                LabeledContent("중복", value: copies.isEmpty ? "없음" : "다른 곳에 \(copies.count)개")
                ForEach(copies, id: \.self) { c in
                    Button(relativePath(c)) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c)]) }
                        .buttonStyle(.link).lineLimit(1).truncationMode(.head)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: p.path) {
            loader.image = nil
            loader.camera = []
            let photo = p
            async let img = Task.detached { ThumbStore.image(for: photo) }.value
            async let cam = Task.detached { photo.isVideo ? [] : cameraInfo(photo.url) }.value
            loader.image = await img
            loader.camera = await cam
        }
    }
}

// MARK: - 도움말

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("사진지도 도움말").font(.largeTitle.bold())
                helpSection("세 가지 탭", """
                **전체** — 등록한 폴더의 사진 전부. 위치 필터로 위치 있음·추정·위치 없음만 볼 수 있어요.
                **장소** — 검색하거나 지도를 클릭한 곳의 반경 안 사진.
                **위치 없음** — GPS도 추정도 없는 사진. 위치를 직접 지정하는 곳이에요.
                """)
                helpSection("사진 고르기", """
                **클릭** 한 장만 · **⌘클릭** 여러 장 · **⇧클릭** 범위 · **⌘A** 보이는 사진 모두 · **Esc** 해제
                **화살표** 이동(⇧와 함께 누르면 범위) · **엔터** 열기 · **더블클릭** 열기
                **스페이스** 크게 미리보기(←→로 넘기기) · **⌘I** 사진 정보
                고른 사진을 **끌어다 놓으면** 전부 함께 Finder·블로그 에디터로 옮겨져요.
                """)
                helpSection("지도", """
                장소를 검색(⌘F)하거나 지도를 클릭하면 빨간 원이 생기고, 원 안 사진이 오른쪽에 나와요. 반경은 20m~50km.
                핀 색: 🟠 GPS · 🔵 추정 · 🟣 지정. 숫자는 오른쪽 필터를 그대로 따라요.
                """)
                helpSection("필터 아이콘", """
                강아지만 · 촬영 시간으로 위치 추정 · 추정만(장소 탭) · RAW 포함 · 중복만 · 중복은 1장만 · 라벨 보기
                마우스를 올리면 설명이 나오고, 켜진 아이콘은 파랗게 채워져요.
                """)
                helpSection("위치 정하기", """
                **추정** — GPS 없는 사진은 앞뒤 30분(설정에서 변경) 안의 GPS 사진 위치를 빌려 써요.
                **지정** — 사진을 고르고 장소를 검색해 원을 옮긴 뒤, 아래 작업 막대의 **위치 → 원 위치로 지정**.
                추정이 맞으면 **추정 위치 맞음 · 확정**. 사진 파일은 바뀌지 않고 앱 안에만 저장돼요.
                """)
                helpSection("강아지 찾기", """
                작업 메뉴 → **사진 분석**(맥 안에서만). 틀린 사진은 우클릭 → **강아지임 / 강아지 아님**.
                """)
                helpSection("중복", """
                작업 메뉴 → **중복 검사**. 파일 내용 전체가 같은 사진만 중복이에요.
                사본을 모두 골라 지워도 묶음마다 1장은 자동으로 남겨요.
                """)
                helpSection("드래그 자동 보정", """
                🪄 아이콘(⇧⌘E)을 켜면 블로그·Finder로 끌어갈 때 밝기·대비·색을 자동으로 맞춘 JPG(크기는 원본 그대로)를 넘겨요.
                원본은 그대로이고, 보정본은 임시 파일이라 앱을 끄면 지워져요. 크기는 설정 → 보기에서 바꿔요.
                """)
                helpSection("동영상 → GIF", """
                동영상을 우클릭 → **GIF 만들기…** 시작·길이·크기·부드러움을 고르고 만들면,
                **한 장 최대 용량**(기본 10MB)을 넘지 않게 자동으로 1번·2번…으로 나눠요. 목록에서 블로그로 바로 끌어다 넣어요.
                """)
                helpSection("모으기 · 되돌리기", """
                작업 막대의 **모으기** → 바로가기(원본 그대로) 또는 복사. 첫 번째 사진 폴더 안 _사진지도/모음/ 에 만들어져요.
                위치 지정·강아지 구분·휴지통 이동은 **⌘Z**로 되돌릴 수 있어요.
                """)
                helpSection("메뉴", """
                **작업** — 다시 읽기(⌘R) · 사진 분석 · 중복 검사
                **편집** — 썸네일 만들기(전체)·비우기 · 중복 기준
                **보기** — 탭 전환(⌘1~3) · 라벨 보기(⇧⌘L) · 썸네일 크기(⌘+ ⌘- ⌘0)
                **설정(⌘,)** — 사진 폴더 · 추정 시간 범위 · 썸네일 용량 · 분석
                """)
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    func helpSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(.init(body)).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        }
    }
}

/// 메뉴에서 창을 여는 버튼(창 열기는 View 안에서만 쓸 수 있다)
struct OpenWindowButton: View {
    let title: String
    let id: String
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) { openWindow(id: id) }.keyboardShortcut(key, modifiers: modifiers)
    }
}

@main
struct PhotoMapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup("사진지도") {
            ContentView().environmentObject(model).frame(minWidth: 1000, minHeight: 680)
        }
        .commands {
            // 파일 메뉴: 새 창 대신 사진 정보
            CommandGroup(replacing: .newItem) {
                OpenWindowButton(title: "사진 정보", id: "info", key: "i")
            }
            // 도움말 메뉴
            CommandGroup(replacing: .help) {
                OpenWindowButton(title: "사진지도 도움말", id: "help", key: "?", modifiers: [.command, .shift])
            }
            // 되돌리기: 글자 입력 중이면 글자 되돌리기, 아니면 위치 지정·강아지 구분·휴지통 되돌리기
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoTitle ?? "되돌리기") {
                    if isEditingText() { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { model.undo() }
                }
                .keyboardShortcut("z", modifiers: .command)
                Button(model.redoTitle ?? "다시 실행") {
                    if isEditingText() { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { model.redo() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            // 편집 메뉴 아래쪽
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("보이는 사진 모두 선택  (⌘A)") { model.selectAllVisible() }
                Button("선택 해제  (Esc)") { model.clearSelection() }
                Button("미리보기  (스페이스)") { Preview.toggle(model) }
                Divider()
                Toggle("중복 기준: 파일 이름까지 같아야 중복", isOn: $model.sameNameOnly)
                Divider()
                Button(model.buildingThumbs ? "썸네일 만드는 중…" : "썸네일 만들기 (전체)") { model.buildAllThumbs() }
                    .disabled(model.buildingThumbs || model.analyzing)
                Button("썸네일 비우기") { model.clearThumbs() }
                    .disabled(model.buildingThumbs)
            }
            // 보기 메뉴
            CommandGroup(after: .toolbar) {
                Button("전체") { model.mode = .all }.keyboardShortcut("1", modifiers: .command)
                Button("장소") { model.mode = .map }.keyboardShortcut("2", modifiers: .command)
                Button("위치 없음") { model.mode = .unlocated }.keyboardShortcut("3", modifiers: .command)
                Button("장소 검색") { focusSearch() }.keyboardShortcut("f", modifiers: .command)
                Divider()
                Toggle("사진 라벨 보기 (추정·지정·직접·중복)", isOn: $model.showLabels)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Toggle("드래그할 때 자동 보정", isOn: $model.enhanceOnDrag)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("썸네일 크게") { model.zoomThumbs(16) }.keyboardShortcut("=", modifiers: .command)
                Button("썸네일 작게") { model.zoomThumbs(-16) }.keyboardShortcut("-", modifiers: .command)
                Button("썸네일 기본 크기") { model.thumbSize = 96 }.keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("작업") { WorkMenuItems(model: model, shortcuts: true) }
        }

        Window("사진 정보", id: "info") {
            InfoView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        Window("GIF 만들기", id: "gif") {
            GIFView(job: GIFJob.shared)
        }
        .windowResizability(.contentSize)

        Window("사진지도 도움말", id: "help") {
            HelpView()
        }
        .defaultSize(width: 640, height: 720)

        Settings {
            SettingsView(model: model)
        }
    }
}
