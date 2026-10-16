import Foundation
import Swifter          // SPM: https://github.com/httpswift/swifter

/// Desktop -> phone transfer. Open http://<phone-ip>:8080 on a computer on the same Wi-Fi.
/// Note: Swifter buffers each upload in memory; for multi-GB videos prefer GCDWebServer (streams to disk).
final class WiFiServer: ObservableObject {
    @Published var isRunning = false
    @Published var address: String?
    private var server: HttpServer?

    private static let page = """
    <html><head><meta name=viewport content="width=device-width"></head><body style="font-family:-apple-system;padding:2rem">
    <h2>Send files to your iPhone</h2>
    <form method="POST" action="/upload" enctype="multipart/form-data">
    <input type="file" name="files" multiple><br><br><button>Upload</button></form></body></html>
    """

    func start(port: UInt16 = 8080) {
        let s = HttpServer()
        s["/"] = { _ in .ok(.html(Self.page)) }
        s["/upload"] = { req in
            guard req.method == "POST" else { return .badRequest(nil) }
            let fs = FileService.shared
            for part in req.parseMultiPartFormData() {
                guard let name = part.fileName, !name.isEmpty else { continue }
                let dest = fs.uniqueURL(in: fs.url(for: .downloads), filename: fs.sanitized(name))
                try? Data(part.body).write(to: dest)
            }
            return .movedPermanently("/")
        }
        do {
            try s.start(port, forceIPv4: true)
            server = s
            isRunning = true
            address = Self.wifiAddress().map { "http://\($0):\(port)" } ?? "Connect to Wi-Fi first"
        } catch {
            address = "Could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        server?.stop(); server = nil
        isRunning = false; address = nil
    }

    static func wifiAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var result: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let f = ptr.pointee
            guard f.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: f.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(f.ifa_addr, socklen_t(f.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            result = String(cString: host)
        }
        return result
    }
}
