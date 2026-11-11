import Foundation

enum PanelPlacement {
    static func frame(size:CGSize, anchor:CGPoint, visible:CGRect) -> CGRect {
        let safe = visible.insetBy(dx:8,dy:8)
        let width = min(size.width,safe.width), height = min(size.height,safe.height)
        let x = min(max(anchor.x-width,safe.minX),safe.maxX-width)
        let y = min(max(anchor.y,safe.minY),safe.maxY-height)
        return CGRect(x:x,y:y,width:width,height:height)
    }
    static func interpolate(_ start:CGRect,_ end:CGRect,progress:CGFloat) -> CGRect {
        let t = min(1,max(0,progress))
        func lerp(_ a:CGFloat,_ b:CGFloat) -> CGFloat { a+(b-a)*t }
        return CGRect(x:lerp(start.minX,end.minX),y:lerp(start.minY,end.minY),
                      width:lerp(start.width,end.width),height:lerp(start.height,end.height))
    }
}
