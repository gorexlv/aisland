import Cocoa

func reviewPNG(_ image: NSImage) throws -> Data {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let data = rep.representation(using:.png,properties:[:]) else { throw NotesFailure(detail:"无法生成批阅图片") }
    return data
}
func annotatedReviewImage(_ snapshot: ReviewSnapshot, regions: [ReviewRegion]) -> NSImage {
    NSImage(size:snapshot.image.size,flipped:false) { bounds in
        snapshot.image.draw(in:bounds)
        for region in regions {
            let rect = CGRect(x:region.rect.minX*bounds.width,y:(1-region.rect.maxY)*bounds.height,width:region.rect.width*bounds.width,height:region.rect.height*bounds.height)
            NSColor.systemOrange.setStroke(); let path = NSBezierPath(rect:rect); path.lineWidth = 3; path.stroke()
            let badge = NSRect(x:rect.minX,y:rect.maxY-22,width:32,height:22)
            NSColor.systemOrange.setFill(); badge.fill()
            ("#\(region.number)" as NSString).draw(in:badge.insetBy(dx:3,dy:2),withAttributes:[.font:NSFont.boldSystemFont(ofSize:12),.foregroundColor:NSColor.black])
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
