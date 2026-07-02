#!/usr/bin/env swift
import Foundation
import Network

struct PeerMessage: Codable {
    enum Action: String, Codable {
        case ping, pong, status
    }
    let action: Action
    let deviceAddress: String?
    let hostName: String?
    let token: String?
}

let host = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "127.0.0.1"
let port: UInt16 = CommandLine.arguments.count > 2 ? UInt16(CommandLine.arguments[2])! : 9847
let token = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "test-token"

let message = PeerMessage(action: .ping, deviceAddress: nil, hostName: "TestClient", token: token)
let data = try JSONEncoder().encode(message)
var framed = Data()
var length = UInt32(data.count).bigEndian
framed.append(Data(bytes: &length, count: 4))
framed.append(data)

let sem = DispatchSemaphore(value: 0)
var result = "timeout"

let connection = NWConnection(
    host: NWEndpoint.Host(host),
    port: NWEndpoint.Port(rawValue: port)!,
    using: .tcp
)

connection.stateUpdateHandler = { state in
    switch state {
    case .ready:
        connection.send(content: framed, completion: .contentProcessed { _ in
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
                guard let header, header.count == 4 else {
                    result = "no response header"
                    sem.signal()
                    return
                }
                let bodyLen = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                connection.receive(minimumIncompleteLength: Int(bodyLen), maximumLength: Int(bodyLen)) { body, _, _, _ in
                    defer { sem.signal() }
                    guard let body, let reply = try? JSONDecoder().decode(PeerMessage.self, from: body) else {
                        result = "invalid response body"
                        return
                    }
                    result = "action=\(reply.action.rawValue) host=\(reply.hostName ?? "nil")"
                }
            }
        })
    case .failed(let error):
        result = "failed: \(error.localizedDescription)"
        sem.signal()
    default:
        break
    }
}

connection.start(queue: .global())
_ = sem.wait(timeout: .now() + 5)
connection.cancel()
print(result)