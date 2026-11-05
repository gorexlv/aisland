import Cocoa
import CoreText

func reviewPNG(_ image: NSImage) throws -> Data {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let data = rep.representation(using:.png,properties:[:]) else { throw NotesFailure(detail:"无法生成批阅图片") }
    return data
}
func annotatedReviewImage(_ snapshot: ReviewSnapshot, regions: [ReviewRegion]) -> NSImage {
    NSImage(size:snapshot.image.size,flipped:false) { bounds in
        snapshot.image.draw(in:bounds)
        for region in regions {
            let rect = CGRect(x:region.rect.minX*bounds.width,y:(1-region.rect.maxY)*bounds.height,width:region.rect.width*bounds.width,height:region.rect.height*bounds.height)
            NSColor.systemBlue.setStroke(); let path = NSBezierPath(rect:rect); path.lineWidth = 3; path.stroke()
            let badge = NSRect(x:rect.minX,y:rect.maxY-22,width:32,height:22)
            NSColor.systemBlue.setFill(); badge.fill()
            ("#\(region.number)" as NSString).draw(in:badge.insetBy(dx:3,dy:2),withAttributes:[.font:NSFont.boldSystemFont(ofSize:12),.foregroundColor:NSColor.white])
        }
        return true
    }
}
func reviewSnapshotNotes(_ shot: ReviewSnapshot, regions: [ReviewRegion]) -> String {
    let marks = regions.filter { $0.snapshotID == shot.id }
    return marks.isEmpty ? "（未添加标记）" : marks.map { "#\($0.number) " + ($0.feedback.isEmpty ? "（未填写意见）" : $0.feedback) }.joined(separator:"\n\n")
}
func reviewPlainText(target: String, regions: [ReviewRegion], snapshots: [ReviewSnapshot]) -> String {
    target + "\n\n" + snapshots.enumerated().map { index, shot in
        "画面 \(index+1)\n" + reviewSnapshotNotes(shot,regions:regions)
    }.joined(separator:"\n\n")
}
func reviewRichText(target: String, regions: [ReviewRegion], snapshots: [ReviewSnapshot]) throws -> NSAttributedString {
    let result = NSMutableAttributedString(string:target+"\n\n",attributes:[.font:NSFont.boldSystemFont(ofSize:18),.foregroundColor:NSColor.black])
    for (index, shot) in snapshots.enumerated() {
        result.append(NSAttributedString(string:"画面 \(index+1)\n",attributes:[.font:NSFont.boldSystemFont(ofSize:14),.foregroundColor:NSColor.black]))
        let image = annotatedReviewImage(shot,regions:regions.filter{$0.snapshotID == shot.id})
        let wrapper = FileWrapper(regularFileWithContents:try reviewPNG(image))
        wrapper.preferredFilename = "review-screen-\(index+1).png"
        let attachment = NSTextAttachment(fileWrapper:wrapper)
        let scale = min(1,480/max(1,image.size.width))
        let preview = NSImage(size:NSSize(width:image.size.width*scale,height:image.size.height*scale),flipped:false) { bounds in image.draw(in:bounds); return true }
        attachment.attachmentCell = NSTextAttachmentCell(imageCell:preview)
        result.append(NSAttributedString(attachment:attachment))
        result.append(NSAttributedString(string:"\n"+reviewSnapshotNotes(shot,regions:regions)+"\n\n",attributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.black]))
    }
    return result
}
func copyReview(target: String, regions: [ReviewRegion], snapshots: [ReviewSnapshot], pasteboard: NSPasteboard = .general) throws {
    let rich = try reviewRichText(target:target,regions:regions,snapshots:snapshots)
    guard let rtfd = rich.rtfd(from:NSRange(location:0,length:rich.length),documentAttributes:[:]) else { throw NotesFailure(detail:"无法生成图文批阅") }
    // A single rich-text item preserves ordering and images in Notes/TextEdit/Pages.
    let item = NSPasteboardItem()
    item.setData(rtfd,forType:.rtfd)
    item.setString(reviewPlainText(target:target,regions:regions,snapshots:snapshots),forType:.string)
    var html = "<html><body><h2>" + htmlEscape(target) + "</h2>"
    for (index, shot) in snapshots.enumerated() {
        let data = try reviewPNG(annotatedReviewImage(shot,regions:regions.filter{$0.snapshotID == shot.id}))
        html += "<h3>画面 \(index+1)</h3><img width=\"480\" src=\"data:image/png;base64,\(data.base64EncodedString())\"><p>" + htmlEscape(reviewSnapshotNotes(shot,regions:regions)).replacingOccurrences(of:"\n",with:"<br>") + "</p>"
    }
    item.setString(html+"</body></html>",forType:.html)
    // Image-only targets get one composite card; rich-text targets keep individual attachments.
    let text = NSMutableAttributedString(attributedString:rich)
    let width: CGFloat = 520
    let natural = text.boundingRect(with:NSSize(width:width-32,height:100000),options:[.usesLineFragmentOrigin,.usesFontLeading]).height + 32
    let scale = min(1,16000/max(natural,1))
    let composite = NSImage(size:NSSize(width:width*scale,height:natural*scale),flipped:false) { bounds in
        NSColor.white.setFill(); bounds.fill()
        let transform = NSAffineTransform(); transform.scale(by:scale); transform.concat()
        text.draw(with:NSRect(x:16,y:16,width:width-32,height:natural-32),options:[.usesLineFragmentOrigin,.usesFontLeading])
        return true
    }
    item.setData(try reviewPNG(composite),forType:.png)
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else { throw NotesFailure(detail:"系统剪贴板写入失败") }
}

struct StoredReviewShot: Codable {
    let id: UUID
    let frame: CGRect
    var capturedAt: Date? = nil
}
struct StoredReviewSession: Codable {
    var version = 1
    let target: ScreenTarget?
    let shots: [StoredReviewShot]
    let regions: [ReviewRegion]
    let selectedID: UUID?
}
struct ReviewSavePayload {
    let session: StoredReviewSession
    let originals: [UUID:Data]
    let text: String
}
/// Serial disk transactions; manifest is committed last so recovery never references
/// an image that has not reached disk. Only immutable PNG bytes cross actor boundaries.
actor ReviewStore {
    static func defaultRoot() throws -> URL {
        try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("DuckIsland/Reviews")
    }
    func save(_ payload: ReviewSavePayload, folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        for shot in payload.session.shots {
            let url = folder.appendingPathComponent("original-\(shot.id).png")
            if !fm.fileExists(atPath:url.path) {
                guard let data = payload.originals[shot.id] else { throw NotesFailure(detail:"截图原图缺失") }
                try data.write(to:url,options:.atomic)
            }
        }
        for (index, shot) in payload.session.shots.enumerated() {
            let geometry = payload.session.regions.filter { $0.snapshotID == shot.id }.map { region -> ReviewRegion in
                var region = region; region.feedback = ""; return region
            }
            let signatureEncoder = JSONEncoder(); signatureEncoder.outputFormatting = .sortedKeys
            let signature = try signatureEncoder.encode(geometry)
            let signatureURL = folder.appendingPathComponent("geometry-\(shot.id).json")
            let markedURL = folder.appendingPathComponent(String(format:"%02d",index+1)+"-"+shot.id.uuidString+".png")
            if (try? Data(contentsOf:signatureURL)) != signature || !fm.fileExists(atPath:markedURL.path) {
                let original = try Data(contentsOf:folder.appendingPathComponent("original-\(shot.id).png"))
                try markedReviewPNG(original,regions:geometry).write(to:markedURL,options:.atomic)
                try signature.write(to:signatureURL,options:.atomic)
            }
        }
        try JSONEncoder().encode(payload.session.regions).write(to:folder.appendingPathComponent("regions.json"),options:.atomic)
        try payload.text.write(to:folder.appendingPathComponent("review.txt"),atomically:true,encoding:.utf8)
        try JSONEncoder().encode(payload.session).write(to:folder.appendingPathComponent("session.json"),options:.atomic)
        // After committing the manifest, remove obsolete exported images. Undo retains
        // original bytes in memory and writes them again through the same transaction.
        let liveIDs = Set(payload.session.shots.map { $0.id.uuidString })
        let numbered = Set(payload.session.shots.enumerated().map { String(format:"%02d",$0.offset+1)+"-"+$0.element.id.uuidString+".png" })
        for url in try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) {
            let name = url.lastPathComponent
            if name.hasPrefix("original-"), name.hasSuffix(".png") {
                let id = String(name.dropFirst(9).dropLast(4))
                if UUID(uuidString:id) != nil && !liveIDs.contains(id) { try fm.removeItem(at:url) }
            } else if name.hasPrefix("geometry-"), name.hasSuffix(".json") {
                let id = String(name.dropFirst(9).dropLast(5))
                if UUID(uuidString:id) != nil && !liveIDs.contains(id) { try fm.removeItem(at:url) }
            } else if name.hasSuffix(".png"), name.count >= 43,
                      UUID(uuidString:String(name.suffix(40).prefix(36))) != nil,
                      !numbered.contains(name) { try fm.removeItem(at:url) }
        }
    }
    func latest(root: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath:root.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            .filter { FileManager.default.fileExists(atPath:$0.appendingPathComponent("session.json").path) }
            .sorted {
                let lhs = (try? $0.appendingPathComponent("session.json").resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.appendingPathComponent("session.json").resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }.first
    }
    func load(folder: URL) throws -> ReviewSavePayload {
        let session = try JSONDecoder().decode(StoredReviewSession.self,from:Data(contentsOf:folder.appendingPathComponent("session.json")))
        let ids = Set(session.shots.map(\.id))
        guard session.version == 1, ids.count == session.shots.count,
              Set(session.regions.map(\.id)).count == session.regions.count,
              session.selectedID == nil || session.regions.contains(where: { $0.id == session.selectedID }),
              session.regions.allSatisfy({ ids.contains($0.snapshotID) && $0.rect.minX >= 0 && $0.rect.minY >= 0 && $0.rect.maxX <= 1 && $0.rect.maxY <= 1 && $0.rect.width > 0 && $0.rect.height > 0 }) else {
            throw NotesFailure(detail:"批阅数据损坏或版本不受支持")
        }
        var originals: [UUID:Data] = [:]
        for shot in session.shots {
            let data = try Data(contentsOf:folder.appendingPathComponent("original-\(shot.id).png"))
            guard let source = CGImageSourceCreateWithData(data as CFData,nil), CGImageSourceCreateImageAtIndex(source,0,nil) != nil else { throw NotesFailure(detail:"批阅原图损坏") }
            originals[shot.id] = data
        }
        return ReviewSavePayload(session:session,originals:originals,text:"")
    }
}

/// Core Graphics/Core Text rendering uses no shared AppKit image or graphics state.
func markedReviewPNG(_ png: Data, regions: [ReviewRegion]) throws -> Data {
    guard let source = CGImageSourceCreateWithData(png as CFData,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil),
          let context = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NotesFailure(detail:"无法绘制批阅图片") }
    let width = CGFloat(image.width), height = CGFloat(image.height)
    context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
    context.setStrokeColor(CGColor(red:0,green:0.478,blue:1,alpha:1)); context.setLineWidth(3)
    for region in regions {
        let rect = CGRect(x:region.rect.minX*width,y:(1-region.rect.maxY)*height,width:region.rect.width*width,height:region.rect.height*height)
        context.stroke(rect)
        let badge = CGRect(x:rect.minX,y:rect.maxY-22,width:32,height:22)
        context.setFillColor(CGColor(red:0,green:0.478,blue:1,alpha:1)); context.fill(badge)
        let attributes: [NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica-Bold" as CFString,12,nil),NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:"#\(region.number)",attributes:attributes))
        context.textPosition = CGPoint(x:badge.minX+3,y:badge.minY+5); CTLineDraw(line,context)
    }
    let data = NSMutableData()
    guard let result = context.makeImage(), let destination = CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil) else { throw NotesFailure(detail:"无法编码批阅图片") }
    CGImageDestinationAddImage(destination,result,nil)
    guard CGImageDestinationFinalize(destination) else { throw NotesFailure(detail:"无法保存批阅图片") }
    return data as Data
}
