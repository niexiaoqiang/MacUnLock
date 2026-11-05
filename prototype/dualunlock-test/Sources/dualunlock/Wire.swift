import Foundation
import CryptoKit
import Network

/// 一条请求：单行 JSON，HMAC-SHA256 签名，带时间戳和随机数防重放。
struct Request: Codable {
    var cmd: String      // unlock | lock | ping
    var ts: Double
    var nonce: String
    var sig: String

    static func make(_ cmd: String, key: Data) -> Request {
        var r = Request(cmd: cmd, ts: Date().timeIntervalSince1970, nonce: UUID().uuidString, sig: "")
        r.sig = r.signature(key: key)
        return r
    }

    func signature(key: Data) -> String {
        let msg = "\(cmd)|\(String(format: "%.3f", ts))|\(nonce)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key))
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

struct Response: Codable {
    var ok: Bool
    var msg: String
    var serverMs: Double  // 服务端处理耗时
}

/// 防重放：时间窗口 ±15 秒，窗口内 nonce 不可重复。
final class ReplayGuard {
    private var seen: [String: Double] = [:]
    private let lock = NSLock()
    let window: Double = 15

    func check(_ r: Request, key: Data) -> String? {
        let now = Date().timeIntervalSince1970
        guard abs(now - r.ts) <= window else { return "时间戳超出窗口（两台 Mac 的时钟是否一致？）" }
        guard constantTimeEqual(r.signature(key: key), r.sig) else { return "签名错误" }
        lock.lock(); defer { lock.unlock() }
        seen = seen.filter { now - $0.value <= window * 2 }
        guard seen[r.nonce] == nil else { return "重放请求" }
        seen[r.nonce] = now
        return nil
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// 发送一条请求并等待单行响应。返回响应和往返耗时（毫秒）。
func sendRequest(host: String, port: UInt16, cmd: String, key: Data,
                 timeout: TimeInterval = 5) throws -> (Response, Double) {
    let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let queue = DispatchQueue(label: "dualunlock.client")
    let done = DispatchSemaphore(value: 0)
    var result: Result<Response, Error> = .failure(NSError(domain: "dualunlock", code: 1,
                                                         userInfo: [NSLocalizedDescriptionKey: "超时"]))
    let start = DispatchTime.now()

    conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
            var line = try! JSONEncoder().encode(Request.make(cmd, key: key))
            line.append(0x0A)
            conn.send(content: line, completion: .contentProcessed { _ in })
            readLine(conn) { data in
                if let data, let resp = try? JSONDecoder().decode(Response.self, from: data) {
                    result = .success(resp)
                } else {
                    result = .failure(NSError(domain: "dualunlock", code: 2,
                                              userInfo: [NSLocalizedDescriptionKey: "无效响应"]))
                }
                done.signal()
            }
        case .failed(let e), .waiting(let e):
            result = .failure(e)
            done.signal()
        default: break
        }
    }
    conn.start(queue: queue)
    _ = done.wait(timeout: .now() + timeout)
    conn.cancel()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    return (try result.get(), ms)
}

/// 读取到换行为止（最多 4KB）。
func readLine(_ conn: NWConnection, buffer: Data = Data(), completion: @escaping (Data?) -> Void) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
        var buf = buffer
        if let data { buf.append(data) }
        if let nl = buf.firstIndex(of: 0x0A) {
            completion(buf.prefix(upTo: nl))
        } else if isComplete || error != nil || buf.count > 4096 {
            completion(nil)
        } else {
            readLine(conn, buffer: buf, completion: completion)
        }
    }
}
