import AppKit
import Foundation
let folder = URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let n = CGFloat(size*scale)
        let image = NSImage(size:NSSize(width:n,height:n)); image.lockFocus()
        NSColor(calibratedRed:0.96,green:0.965,blue:0.95,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:n*0.05,y:n*0.05,width:n*0.9,height:n*0.9),xRadius:n*0.2,yRadius:n*0.2).fill()
        NSColor(calibratedRed:0.13,green:0.19,blue:0.22,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:n*0.16,y:n*0.32,width:n*0.68,height:n*0.36),xRadius:n*0.18,yRadius:n*0.18).fill()
        NSColor(calibratedRed:0.96,green:0.965,blue:0.95,alpha:1).setStroke()
        let ring = NSBezierPath(ovalIn:NSRect(x:n*0.28,y:n*0.405,width:n*0.19,height:n*0.19))
        ring.lineWidth = n*0.036; ring.stroke()
        let arrow = NSBezierPath(); arrow.move(to:NSPoint(x:n*0.61,y:n*0.46)); arrow.line(to:NSPoint(x:n*0.67,y:n*0.53)); arrow.line(to:NSPoint(x:n*0.73,y:n*0.46)); arrow.lineWidth = n*0.03; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
        bitmap.size = NSSize(width:n,height:n)
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
