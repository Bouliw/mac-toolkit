// Helper for WallperSync: grabs a frame from a video with Apple's colour pipeline (like Wallper does)
// and sets an image as the system wallpaper on every screen.
//   wallper-frame frame <video> <output.png>
//   wallper-frame set <image>
import Foundation
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: wallper-frame frame <video> <output.png> | set <image>") }

switch args[1] {
case "frame":
    guard args.count >= 4 else { fail("usage: wallper-frame frame <video> <output.png>") }
    let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image: CGImage
    do { image = try await generator.image(at: .zero).image }
    catch { fail("frame extraction failed: \(error)") }
    let out = URL(fileURLWithPath: args[3])
    guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("could not create the output file") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("could not write the output file") }
    print("\(image.width)x\(image.height) \((image.colorSpace?.name as String?) ?? "?")")
case "set":
    let url = URL(fileURLWithPath: args[2])
    var updated = 0
    for screen in NSScreen.screens {
        do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]); updated += 1 }
        catch { FileHandle.standardError.write("screen skipped: \(error)\n".data(using: .utf8)!) }
    }
    print("screens updated: \(updated)")
default:
    fail("unknown command")
}
