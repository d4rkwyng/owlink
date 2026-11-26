// Checks an EdDSA (ed25519) signature the way Sparkle checks an update:
// over the archive's bytes, with the public key the app ships
// (SUPublicEDKey). Scripts/release.sh --appcast runs it after sign_update,
// so a private key that doesn't match the app's public key stops the
// release instead of shipping an update every copy would refuse.
// Reads no private key.
//
//   swift Scripts/ed-verify.swift <public-key-base64> <signature-base64> <file>
//
// Exit 0: valid. 1: invalid. 2: bad arguments (not base64, wrong length,
// no such file).
import CryptoKit
import Foundation

let args = CommandLine.arguments.dropFirst()
func usage(_ why: String) -> Never {
    FileHandle.standardError.write(Data("ed-verify: \(why)\n".utf8))
    exit(2)
}
guard args.count == 3 else { usage("usage: ed-verify.swift <public-key-base64> <signature-base64> <file>") }
let a = Array(args)
guard let keyBytes = Data(base64Encoded: a[0]), keyBytes.count == 32 else { usage("the public key is not base64 for 32 bytes") }
guard let sig = Data(base64Encoded: a[1]), sig.count == 64 else { usage("the signature is not base64 for 64 bytes") }
guard let data = FileManager.default.contents(atPath: a[2]) else { usage("can't read \(a[2])") }
guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else { usage("not an ed25519 public key") }
if key.isValidSignature(sig, for: data) {
    print("ed-verify: signature valid for \(a[2])")
    exit(0)
}
FileHandle.standardError.write(Data("ed-verify: signature does NOT match the public key\n".utf8))
exit(1)
