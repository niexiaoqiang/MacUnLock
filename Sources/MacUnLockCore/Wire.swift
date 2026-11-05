import Foundation
import CryptoKit
import Network

/// 一条请求：单行 JSON，HMAC-SHA256 签名，带时间戳和随机数防重放。
public struct Request: Codable {
    public var cmd: String      // unlock | lock | ping
    public var ts: Double
    public var nonce: String
    public var sig: String

    public static func make(_ cmd: String, key: Data) -> Request {
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

public struct Response: Codable {
    public var ok: Bool
    public var msg: String
    public var serverMs: Double  // 对方处理耗时
    public var locked: Bool?     // 对方处理完成后是否处于锁屏

    public init(ok: Bool, msg: String, serverMs: Double = 0, locked: Bool? = nil) {
        self.ok = ok; self.msg = msg; self.serverMs = serverMs; self.locked = locked
    }
}

/// 防重放：时间窗口 ±15 秒，窗口内 nonce 不可重复。
final class ReplayGuard {
    private var seen: [String: Double] = [:]
    private let lock = NSLock()
    let window: Double = 15

    func check(_ r: Request, key: Data) -> String? {
        let now = Date().timeIntervalSince1970
        guard abs(now - r.ts) <= window else { return "时间戳超出窗口（两台 Mac 的时钟是否一致？）" }
        guard constantTimeEqual(r.signature(key: key), r.sig) else { return "签名错误（两台的密钥不一致？）" }
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

public struct WireError: LocalizedError {
    public let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

/// 把常见的网络错误翻译成用户能看懂的中文。
public func friendlyMessage(_ error: Error) -> String {
    if let e = error as? NWError {
        switch e {
        case .posix(.ECONNREFUSED): return "对方没有运行 MacUnLock"
        case .posix(.ETIMEDOUT): return "连接超时"
        case .posix(.EHOSTUNREACH), .posix(.EHOSTDOWN): return "对方不在线或已睡眠"
        case .posix(.ENETUNREACH), .posix(.ENETDOWN): return "本机网络不可用"
        case .posix(.EADDRINUSE): return "端口已被占用（是否还有另一个 MacUnLock 或原型在运行？）"
        case .dns: return "找不到这个主机名"
        default: break
        }
    }
    return error.localizedDescription
}

/// 发送一条请求并等待单行响应。返回响应和往返耗时（毫秒）。阻塞调用，不要在主线程用。
public func sendRequest(host: String, port: UInt16, cmd: String, key: Data,
                        timeout: TimeInterval = 5) throws -> (Response, Double) {
    // .local 主机名常同时解析出 IPv6 链路本地地址，先试 IPv6 会多等约 0.5 秒，因此局域网内优先走 IPv4
    let params = NWParameters.tcp
    if !host.contains(":"), let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
        ip.version = .v4
    }
    let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    let queue = DispatchQueue(label: "macunlock.client")
    let done = DispatchSemaphore(value: 0)
    var result: Result<Response, Error> = .failure(WireError("连接超时"))
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
                    result = .failure(WireError("对方返回了无效响应"))
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
    return (try queue.sync { try result.get() }, ms)
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
