// Susu.app entry point. All UI lives in the SusuApp library (previews and snapshot tests import it).
import Foundation
import SusuApp
import SusuCore

// `Susu --set-key groq < keyfile`: stores a key as Susu itself, so the Keychain item belongs to Susu
// and macOS never asks "Susu wants to access…" (an item written by another tool triggers that prompt).
let args = CommandLine.arguments
if args.count == 3, args[1] == "--set-key" {
    let key = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { FileHandle.standardError.write(Data("empty key on stdin\n".utf8)); exit(1) }
    do { try SecretStore().set(key, for: ProviderID(stringLiteral: args[2])); exit(0) } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
}

SusuAppMain.run()
