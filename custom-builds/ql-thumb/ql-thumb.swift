// ql-thumb <size> <input> <output.png> — one Quick Look thumbnail, as a PNG.
//
// Why not `qlmanage -t`: qlmanage is an app bundle, and every run registers
// with LaunchServices as a foreground application. On exit the registration
// stays behind ("exited-with-subordinates"), and the Dock shows a qlmanage icon
// that bounces until it is clicked. Measured on macOS 27: one stale entry per
// run, whatever the environment (LSUIElement, env -i, launchctl asuser). This
// is a plain command-line process, which LaunchServices never lists.
//
// <size> is the longest side in pixels. Exit 0 with the PNG written, 1 when
// Quick Look has no thumbnail for the file, 2 on a usage error. The caller
// bounds the run: a generator can stall on corrupt or cloud-backed files.
import Foundation
import QuickLookThumbnailing
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count == 4, let size = Double(a[1]), size > 0 else {
    FileHandle.standardError.write("usage: ql-thumb <size> <input> <output.png>\n".data(using: .utf8)!)
    exit(2)
}
let req = QLThumbnailGenerator.Request(
    fileAt: URL(fileURLWithPath: a[2]), size: CGSize(width: size, height: size),
    scale: 1, representationTypes: .thumbnail)
let done = DispatchSemaphore(value: 0)
var status: Int32 = 1
QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, err in
    defer { done.signal() }
    guard let image = rep?.cgImage else {
        FileHandle.standardError.write("ql-thumb: \(err?.localizedDescription ?? "no thumbnail")\n".data(using: .utf8)!)
        return
    }
    let out = URL(fileURLWithPath: a[3]) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(out, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    if CGImageDestinationFinalize(dest) { status = 0 }
}
done.wait()
exit(status)
