// Prints the EdDSA (ed25519) PUBLIC key that belongs to a Sparkle private
// key file, so a release can check, before it signs anything, that the key
// it was given is the one whose public half the app ships (SUPublicEDKey,
// Scripts/sparkle-defaults.sh). .github/workflows/release.yml and
// verify-sparkle-key.yml run it on the temp key file they write from the
// SPARKLE_ED_PRIVATE_KEY secret.
//
//   swift Scripts/sparkle-public-key.swift <key-file>
//
// The file is what `generate_keys -x` exports and `sign_update
// --ed-key-file` reads: the 32-byte private seed as base64, possibly with a
// trailing newline. Output: the public key, base64 for 32 bytes, and
// nothing else. The private key is never printed, not even in part, and no
// error message quotes the file's contents (only its byte count).
//
// Exit 0: printed. 2: unreadable file, not base64, or not a 32-byte seed.
import CryptoKit
import Foundation

func fail(_ why: String) -> Never {
    FileHandle.standardError.write(Data("sparkle-public-key: \(why)\n".utf8))
    exit(2)
}
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 1 else { fail("usage: sparkle-public-key.swift <key-file>") }
guard let raw = FileManager.default.contents(atPath: args[0]) else { fail("can't read the key file") }
guard let text = String(data: raw, encoding: .utf8) else { fail("the key file is not text (base64 expected)") }
let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
guard !trimmed.isEmpty else { fail("the key file is empty") }
guard let seed = Data(base64Encoded: trimmed) else { fail("the key file is not base64") }
guard seed.count == 32 else {
    fail("the key file decodes to \(seed.count) bytes, not a 32-byte ed25519 seed (export it with generate_keys -x)")
}
guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { fail("not an ed25519 private key") }
print(key.publicKey.rawRepresentation.base64EncodedString())
