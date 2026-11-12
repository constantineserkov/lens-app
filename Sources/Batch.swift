import AppKit
import Foundation

enum CaptureMode:String { case instant, batch }

struct BatchItem:Codable,Identifiable {
    let image_index:Int
    let part_index:Int
    let result:Answer
    var id:String { "\(image_index)-\(part_index)" }
}
struct BatchAnswer:Codable {
    let items:[BatchItem]
    func validated(imageCount:Int)throws->BatchAnswer {
        guard imageCount > 0,!items.isEmpty,Set(items.map(\.id)).count == items.count,
              Set(items.map(\.image_index)) == Set(1...imageCount),
              items.allSatisfy({ $0.part_index > 0 }) else {
            throw LensError.message("Some batch answers are missing or numbered incorrectly. Your screenshots are saved. Try again.")
        }
        for item in items { _ = try item.result.validated() }
        for index in 1...imageCount {
            let parts = items.filter { $0.image_index == index }.map(\.part_index).sorted()
            guard parts == Array(1...parts.count) else { throw LensError.message("A question is missing from the batch results. Try again.") }
        }
        return BatchAnswer(items:items.sorted { ($0.image_index,$0.part_index) < ($1.image_index,$1.part_index) })
    }
    var taskCountText:String { countText(items.count,one:"question",many:"questions") }
    var answerCountText:String { countText(items.count,one:"answer",many:"answers") }
    var summary:Answer {
        Answer(status:"ok",task:"Batch · \(taskCountText)",answer:items.enumerated().map {
            "\($0.offset+1). \($0.element.result.status == "ok" ? $0.element.result.answer : "Needs clarification")"
        }.joined(separator:"\n"),format_note:"",solution:"",warnings:[])
    }
}

struct PendingShot:Codable,Identifiable {
    let id:UUID
    let createdAt:Date
    var filename:String { "\(id.uuidString).png" }
}

/// Originals stay available until a completed batch has been saved to history.
final class QueueStore {
    let directory:URL
    var manifest:URL { directory.appendingPathComponent("queue.json") }
    private(set) var shots:[PendingShot] = []
    private var loaded = false
    init(directory:URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Lens/Pending",isDirectory:true)
    }
    func url(for shot:PendingShot)->URL { directory.appendingPathComponent(shot.filename) }
    @discardableResult func load()throws->[PendingShot] {
        if FileManager.default.fileExists(atPath:manifest.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let saved = try decoder.decode([PendingShot].self,from:Data(contentsOf:manifest))
            guard Set(saved.map(\.id)).count == saved.count,
                  saved.allSatisfy({ FileManager.default.isReadableFile(atPath:url(for:$0).path) }) else {
                throw LensError.message("Could not load the screenshot queue. Existing files were kept.")
            }
            shots = saved
        }
        loaded = true; return shots
    }
    private func save(_ next:[PendingShot])throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(next)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try data.write(to:manifest,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifest.path)
        shots = next
    }
    @discardableResult func add(_ file:URL)throws->PendingShot {
        if !loaded { try load() }
        guard let image = NSImage(contentsOf:file),image.size.width > 8,image.size.height > 8,
              let tiff = image.tiffRepresentation,let bitmap = NSBitmapImageRep(data:tiff),
              let png = bitmap.representation(using:.png,properties:[:]) else { throw LensError.message("Could not read the image.") }
        let shot = PendingShot(id:UUID(),createdAt:Date())
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let destination = url(for:shot)
        try png.write(to:destination,options:.atomic)
        do {
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
            try save(shots+[shot]); return shot
        } catch { try? FileManager.default.removeItem(at:destination); throw error }
    }
    func remove(_ ids:Set<UUID>)throws {
        if !loaded { try load() }
        let removed = shots.filter { ids.contains($0.id) }
        try save(shots.filter { !ids.contains($0.id) })
        for shot in removed { try? FileManager.default.removeItem(at:url(for:shot)) }
    }
}

private func countText(_ count:Int,one:String,many:String)->String {
    "\(count) \(count == 1 ? one : many)"
}
