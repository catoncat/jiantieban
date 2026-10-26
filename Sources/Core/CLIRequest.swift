import Foundation

public struct CLIError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String
    public let exitCode: Int32
    public let clipboardChanged: Bool?
    public init(_ code: String, _ message: String, exitCode: Int32 = 1, clipboardChanged: Bool? = nil) {
        self.code = code; self.message = message; self.exitCode = exitCode; self.clipboardChanged = clipboardChanged
    }
    public var errorDescription: String? { message }
}

/// Flat, compatible CLI grammar. Parsing never touches storage, preferences, or UI.
public struct CLIRequest: Sendable {
    public let command: String
    public var json = false
    public var raw = false
    public var positional: [String] = []
    public var page = 1
    public var pageSize = 80
    public var kind: ClipItemKind?
    public var favorite = false
    public var secret = false
    public var stdin = false
    public var setFavorite: Bool?
    public var selector: HeadlessPasteSelector?
    public var paste: HeadlessPasteRequest?
    public var confirmed = false

    public static let commands: Set<String> = ["help", "version", "list", "search", "get", "copy", "paste", "add-text", "add-image", "fav", "delete", "clear", "stats", "mark-secret", "watch", "bench", "config", "doctor", "secrets", "annotate", "resolve", "unmark-secret"]

    public static func wantsJSON(_ arguments: [String]) -> Bool {
        for argument in arguments {
            if argument == "--" || argument == "--literal" { break }
            if argument == "--json" { return true }
        }
        return ["get", "copy", "config", "doctor"].contains(arguments.first ?? "")
    }

    public static func parse(_ arguments: [String]) throws -> CLIRequest {
        func invalid(_ message: String) -> CLIError { CLIError("invalid_arguments", message, exitCode: 2) }
        guard let first = arguments.first else { throw invalid("A command is required.") }
        let command = ["--help", "-h"].contains(first) ? "help" : first
        guard commands.contains(command) else { throw invalid("Unknown command. Run jiantieban help.") }
        if arguments.count == 2 && ["--help", "-h"].contains(arguments[1]) {
            return CLIRequest(command: "help", positional: [command])
        }
        if command == "paste" || command == "copy" {
            do {
                var request = CLIRequest(command: command, json: true)
                let rest = Array(arguments.dropFirst())
                request.paste = try HeadlessPasteRequest.parse(rest)
                return request
            } catch let error as HeadlessPasteError {
                throw CLIError(error.code, error.message, exitCode: error.exitCode)
            }
        }
        var result = CLIRequest(command: command, json: ["get", "config", "doctor"].contains(command))
        var seen = Set<String>()
        var index = 1
        var literal = false
        func positive(_ value: String, limit: Int = Int.max) throws -> Int {
            guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let number = Int(value), number > 0, number <= limit else { throw invalid("Expected a positive integer within the allowed range.") }
            return number
        }
        while index < arguments.count {
            let value = arguments[index]
            if literal { result.positional.append(value); index += 1; continue }
            if value == "--" || value == "--literal" {
                guard value == "--" || ["add-text", "search", "mark-secret", "config"].contains(command) else { throw invalid("Literal arguments are not supported by this command.") }
                literal = true; index += 1; continue
            }
            if !value.hasPrefix("--") { result.positional.append(value); index += 1; continue }
            guard seen.insert(value).inserted else { throw invalid("Duplicate option: \(value).") }
            func require(_ allowed: [String]) throws {
                guard allowed.contains(command) else { throw invalid("Option \(value) is not supported by \(command).") }
            }
            func next() throws -> String {
                index += 1
                guard index < arguments.count else { throw invalid("Option \(value) requires a value.") }
                return arguments[index]
            }
            switch value {
            case "--json":
                try require(["help", "version", "list", "search", "get", "add-text", "add-image", "fav", "delete", "clear", "stats", "mark-secret", "config", "doctor"])
                result.json = true
            case "--raw": try require(["get"]); result.raw = true
            case "--latest": try require(["get"]); result.selector = .latest
            case "--page": try require(["list", "search"]); result.page = try positive(next())
            case "--page-size": try require(["list", "search"]); result.pageSize = try positive(next(), limit: 1000)
            case "--kind":
                try require(["search"])
                guard let kind = ClipItemKind(rawValue: try next()) else { throw invalid("--kind requires text or image.") }
                result.kind = kind
            case "--favorite": try require(["search"]); result.favorite = true
            case "--secret": try require(["search"]); result.secret = true
            case "--stdin": try require(["add-text"]); result.stdin = true
            case "--set":
                try require(["fav"])
                let flag = try next()
                guard flag == "true" || flag == "false" else { throw invalid("--set requires true or false.") }
                result.setFavorite = flag == "true"
            case "--yes": try require(["clear"]); result.confirmed = true
            default: throw invalid("Unknown option. Use -- before flag-looking literal content.")
            }
            index += 1
        }
        func count(_ range: ClosedRange<Int>) throws {
            guard range.contains(result.positional.count) else { throw invalid("Wrong number of arguments for \(command).") }
        }
        func recordID(_ string: String) throws -> Int64 {
            guard !string.isEmpty, string.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let id = Int64(string), id > 0 else { throw invalid("A positive record ID is required.") }
            return id
        }
        switch command {
        case "help":
            try count(0...1)
            if let topic = result.positional.first, !commands.contains(topic) { throw invalid("Unknown help topic.") }
        case "version", "stats", "watch", "doctor": try count(0...0)
        case "clear":
            try count(0...0)
            guard result.confirmed else { throw invalid("clear requires --yes; this deletes all local history, not jt secrets.") }
        case "list":
            try count(0...1)
            if let page = result.positional.first {
                guard !seen.contains("--page") else { throw invalid("Specify the page only once.") }
                result.page = try positive(page)
            }
        case "search": try count(1...Int.max)
        case "get":
            if result.selector == .latest { try count(0...0) }
            else { try count(1...1); result.selector = .id(try recordID(result.positional[0])) }
            guard !(result.raw && seen.contains("--json")) else { throw invalid("--raw and --json are mutually exclusive.") }
        case "delete", "fav": try count(1...1); result.selector = .id(try recordID(result.positional[0]))
        case "mark-secret": try count(1...2); result.selector = .id(try recordID(result.positional[0]))
        case "add-text":
            if result.stdin { try count(0...0); guard !literal else { throw invalid("--stdin cannot be combined with literal input.") } }
            else { try count(1...Int.max) }
        case "add-image": try count(1...1)
        case "bench":
            try count(0...1)
            if let n = result.positional.first { _ = try positive(n, limit: 1_000_000) }
        case "config":
            guard let action = result.positional.first else { throw invalid("config requires get, set, or reset.") }
            switch action {
            case "get": try count(1...2)
            case "set": try count(3...3)
            case "reset": try count(2...2)
            default: throw invalid("config requires get, set, or reset.")
            }
        case "secrets", "annotate", "resolve", "unmark-secret":
            throw CLIError("command_moved", "Secret management belongs to jt; use jt ls, jt mv, jt resolve or jt rm. unmark-secret has been removed.", exitCode: 2)
        default: break
        }
        guard !(result.page - 1).multipliedReportingOverflow(by: result.pageSize).overflow else { throw invalid("Pagination offset is too large.") }
        return result
    }
}
