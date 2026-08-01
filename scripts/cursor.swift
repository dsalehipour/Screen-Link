// Prints the cursor position and every display's global bounds as JSON.
// Used by the input-mapping verification in smoke.mjs.
import CoreGraphics
import Foundation

var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetActiveDisplayList(count, &ids, &count)

let location = CGEvent(source: nil)?.location ?? .zero
let displays = ids.map { id -> String in
    let b = CGDisplayBounds(id)
    return "\"\(id)\":{\"x\":\(b.origin.x),\"y\":\(b.origin.y),\"w\":\(b.width),\"h\":\(b.height)}"
}
print("{\"cursor\":{\"x\":\(location.x),\"y\":\(location.y)},\"displays\":{\(displays.joined(separator: ","))}}")
