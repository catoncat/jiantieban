import Core
import Foundation

enum HeadlessCLITests {
    static let all: [TestCase] = [
        TestCase("CLI parser rejects malformed selectors flags pages before execution") {
            let invalid = [["unknown"], ["get"], ["get", "0"], ["get", "--latest", "1"],
                ["get", "1", "--json", "--raw"], ["list", "-1"], ["list", "--page-size", "1001"],
                ["list", "1", "--page", "2"], ["list", "--page", String(Int.max), "--page-size", "1000"],
                ["stats", "extra"], ["watch", "--json"], ["clear"], ["fav", "1", "--set", "yes"],
                ["add-text", "--stdin", "literal"], ["add-text", "--stdin", "--"],
                ["search", "x", "--kind", "other"], ["version", "--json", "--json"]]
            for args in invalid {
                do { _ = try CLIRequest.parse(args); throw TestFailure("accepted \(args)") }
                catch let error as CLIError { try expectEqual(error.exitCode, 2) }
            }
        },
        TestCase("CLI treats flags after literal delimiter as user data") {
            let request = try CLIRequest.parse(["add-text", "--json", "--", "--stdin", "_debug-panel", "--json"])
            try expect(request.json)
            try expect(!request.stdin)
            try expectEqual(request.positional, ["--stdin", "_debug-panel", "--json"])
            try expect(!CLIRequest.wantsJSON(["add-text", "--", "--json"]))
            let literal = try CLIRequest.parse(["search", "--literal", "--favorite"])
            try expectEqual(literal.positional, ["--favorite"])
            try expect(!literal.favorite)
        },
        TestCase("CLI generic selectors and idempotent favorites parse") {
            try expectEqual(try CLIRequest.parse(["get", "--latest"]).selector, .latest)
            try expectEqual(try CLIRequest.parse(["get", "9223372036854775807", "--raw"]).selector, .id(Int64.max))
            try expectEqual(try CLIRequest.parse(["fav", "12", "--set", "false"]).setFavorite, false)
            try expect(try CLIRequest.parse(["clear", "--yes", "--json"]).confirmed)
            let request = try CLIRequest.parse(["search", "hello", "--kind", "text", "--favorite", "--secret", "--page", "2", "--page-size", "10"])
            try expectEqual(request.page, 2); try expectEqual(request.pageSize, 10)
            try expectEqual(request.kind, .text); try expect(request.favorite && request.secret)
        },
        TestCase("CLI help version config doctor are typed without runtime dependencies") {
            try expectEqual(try CLIRequest.parse(["--help"]).command, "help")
            try expectEqual(try CLIRequest.parse(["get", "--help"]).command, "help")
            try expectEqual(try CLIRequest.parse(["version", "--json"]).command, "version")
            try expectEqual(try CLIRequest.parse(["config", "set", "imagePasteAsFile", "true"]).positional, ["set", "imagePasteAsFile", "true"])
            try expect(try CLIRequest.parse(["doctor"]).json)
        },
        TestCase("CLI DTO keeps Int64 IDs exact and excludes stale secret content") {
            let item = ClipItem(id: Int64.max, kind: .text, content: "DO_NOT_EXPORT", imagePath: "/private/stale", ocrText: "DO_NOT_EXPORT", isSecret: true, secretToken: "jt://secret/example")
            let object = try CLIOutput.object(CLIRecord(item)) as! [String: Any]
            try expectEqual(object["id"] as? String, String(Int64.max))
            try expectEqual(object["content"] as? String, "jt://secret/example")
            try expect(object["image_path"] == nil && object["ocr_text"] == nil)
            let bytes = try CLIOutput.success(command: "get", result: object)
            try expect(!String(decoding: bytes, as: UTF8.self).contains("DO_NOT_EXPORT"))
            let envelope = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            try expectEqual(envelope["schema_version"] as? Int, 1)
            try expectEqual(envelope["ok"] as? Bool, true)
        },
    ]
}
