import AppKit

extension NSPasteboard.PasteboardType {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let png = NSPasteboard.PasteboardType("public.png")
    static let html = NSPasteboard.PasteboardType("public.html")
    static let rtf = NSPasteboard.PasteboardType("public.rtf")
    static let rtfd = NSPasteboard.PasteboardType("com.apple.rtfd")
    static let flatRTFD = NSPasteboard.PasteboardType("com.apple.flat-rtfd")
}

