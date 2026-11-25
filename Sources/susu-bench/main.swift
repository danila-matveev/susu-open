// susu-bench: measurement CLI on the test set. `transcribe` arrives with T1.3, `agent` with T6.9.
import Foundation
import SusuCore

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("usage: susu-bench transcribe --set DIR --provider groq-turbo [--hint FILE] [--hint-raw] [--lead-in TEXT] [--realtime] [--only c01,c02] --out runs/susu-NAME.json\n       susu-bench transcribe --style code|messengers [--stt-run runs/susu-run2.json] [--editor-models a,b] [--dictionary FILE] [--editor-timeout SEC] --out runs/susu-editor.json\n       susu-bench wispr-dictionary --out DIR/dictionary.json\n       susu-bench wispr-import --data DIR [--audio]")
    exit(2)
}
switch command {
case "transcribe":
    await TranscribeCommand.run(Array(args.dropFirst()))
case "wispr-import":
    await WisprImportCommand.run(Array(args.dropFirst()))
case "wispr-dictionary":
    await WisprDictionaryCommand.run(Array(args.dropFirst()))
default:
    FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
    exit(2)
}
