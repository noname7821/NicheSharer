import Foundation
import Network

/// Talks to the jailbreak tweak daemon on 127.0.0.1:17999.
/// One JSON object per line: {"cmd":"pair"} / {"cmd":"stop"} / {"cmd":"status"}.
enum DaemonClient {
    static let port: UInt16 = 17999

    static func send(_ dict: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        guard let line = try? JSONSerialization.data(withJSONObject: dict),
              let port = NWEndpoint.Port(rawValue: port) else {
            completion(nil)
            return
        }
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        var done = false
        func finish(_ result: [String: Any]?) {
            guard !done else { return }
            done = true
            connection.cancel()
            DispatchQueue.main.async { completion(result) }
        }
        var buffer = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                if done { return }
                if let data { buffer.append(data) }
                if let range = buffer.range(of: Data("\n".utf8)) {
                    let lineData = buffer.subdata(in: 0..<range.lowerBound)
                    let json = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
                    finish(json)
                } else {
                    receive()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            if done { return }
            switch state {
            case .ready:
                var packet = line
                packet.append(Data("\n".utf8))
                connection.send(content: packet, completion: .contentProcessed { _ in })
                receive()
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            finish(nil)
        }
    }
}
