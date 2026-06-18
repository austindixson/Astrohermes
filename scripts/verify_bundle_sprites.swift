#!/usr/bin/swift
import AppKit

let appPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        .appendingPathComponent("Pip")
        .path + "/Build/Products/Release/Pip.app"

let bundle = Bundle(path: appPath)!
let names = [
    "rocky-walk-right-f0", "rocky-walk-left-f3", "rocky-turn-3",
    "rocky-idle-right", "rocky-mad-0", "rocky-fall-8", "walk-right-f0",
]
var ok = 0
for name in names {
    guard let url = bundle.url(forResource: name, withExtension: "png"),
          let img = NSImage(contentsOf: url),
          let rep = img.representations.first as? NSBitmapImageRep ?? NSBitmapImageRep(data: img.tiffRepresentation!) else {
        print("FAIL missing/bad: \(name)")
        continue
    }
    let hasAlpha = rep.hasAlpha
    let w = rep.pixelsWide, h = rep.pixelsHigh
    print("OK \(name): \(w)x\(h) alpha=\(hasAlpha)")
    ok += 1
}
print("loaded \(ok)/\(names.count)")
exit(ok == names.count ? 0 : 1)