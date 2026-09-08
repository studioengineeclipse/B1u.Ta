// B1Reference entrypoint.
//
//   conform     read a JSON document on stdin, emit its B1-CANON-1 digest (SPEC/20 §5)
//   references  read an IR on stdin, emit the reference-role analysis
//   selftest    run the reference algebra's own checks

import Foundation

func readStdin() -> Data {
    FileHandle.standardInput.readDataToEndOfFile()
}

func fail(_ token: String) -> Never {
    FileHandle.standardError.write(Data((token + "\n").utf8))
    exit(2)
}

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "conform"

switch command {
case "conform":
    let data = readStdin()
    // Strict decoding: substituting replacement characters for malformed input would silently
    // change the document and therefore its digest.
    guard let text = String(data: data, encoding: .utf8) else {
        fail("B1_ERR_INVALID_UTF8")
    }
    do {
        print(try digestText(text))
    } catch let e as B1Error {
        fail(e.token)
    } catch {
        fail("B1_ERR_PARSE")
    }

case "references":
    let data = readStdin()
    guard let text = String(data: data, encoding: .utf8) else { fail("B1_ERR_INVALID_UTF8") }
    do {
        var parser = CanonParser(text)
        let ir = try parser.parse()
        let bindings = bindingsFromJson(ir["reference_bindings"] ?? .array([]))
        print(try canonicalize(resultToJson(analyze(bindings))))
    } catch let e as B1Error {
        fail(e.token)
    } catch {
        fail("B1_ERR_PARSE")
    }

case "selftest":
    exit(Int32(runSelfTest()))

default:
    FileHandle.standardError.write(Data("usage: b1reference [conform|references|selftest]\n".utf8))
    exit(2)
}
