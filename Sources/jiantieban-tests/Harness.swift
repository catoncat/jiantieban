import Foundation

/// 微型测试 harness：CLT 不含 XCTest/Testing，自研零依赖替代品。
/// 每个测试文件暴露 `static var xxxTests: [TestCase]`，main.swift 汇总运行。

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

struct TestCase {
    let name: String
    let body: @MainActor () throws -> Void

    init(_ name: String, _ body: @escaping @MainActor () throws -> Void) {
        self.name = name
        self.body = body
    }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expectation failed") throws {
    if !condition { throw TestFailure(message()) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "") throws {
    if actual != expected {
        let extra = message().isEmpty ? "" : " — \(message())"
        throw TestFailure("expected \(expected), got \(actual)\(extra)")
    }
}
