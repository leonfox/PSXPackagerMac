import Foundation
import PSXCore

// MARK: - Results

enum Results {
    static let ok: Int32 = 0
    static let error: Int32 = 1
    static let cancelled: Int32 = 2
    static let invalidInput: Int32 = 3
}

// MARK: - Options

struct Options {
    var inputPath: String?
    var outputPath: String?
    var compressionLevel = 5
    var recursive = false
    var discs: String?
    var verbosity = 3
    var overwriteIfExists = false
    var skipIfExists = false
    var fileNameFormat = "%FILENAME%"
    var log = false
    var extractResources = false
    var importResources = false
    var generateResourceFolders = false
    var resourceFormat: String?
    var resourceRoot: String?
}

let helpText = """
  -i, --input                (Group: input) The input file or path to convert. The filename may contain wildcards.

  -o, --output               The output path where the converted file(s) will be written.

  -l, --level                (Default: 5) Set compression level 0-9, default 5.

  -r, --recursive            Recurse subdirectories

  -d, --discs                A comma-separated list of disc numbers to extract from a PBP.

  -v, --verbosity            (Default: 3) Set level of output messages. 1 = Files, Errors and Warnings only, 2 = No
                             Info-level messages, 3 = All messages (default), 4 = Include timestamps

  -x                         If specified, overwrite a file if it exists, otherwise ask confirmation.

  -s, --skip                 If specified, will skip existing files.

  -f, --format               (Default: %FILENAME%) Specify the filename format e.g. [%GAMEID%] [%MAINGAMEID%] %TITLE%
                             (%REGION%) or %FILENAME%

  -g, --log                  If specified, log messages to a file.

  --extract                  If specified, extract resources using the path specified by resource-format. See README for
                             more details.

  --import                   If specified, import resources using the path specified by resource-format. See README for
                             more details.

  --generate                 If specified, create empty resources folder specified by resource-format. See README for
                             more details.

  --resource-format          The format to use with extract/import/generate. See README for more details.

  --resource-root            The path where resource folders will be located. If not specified, the path will be the
                             same as the input file

  --help                     Display this help screen.

  --version                  Display version information.

"""

let heading = "PSXPackager \(PSXPackagerVersion.string)\nCopyright (C) RupertAvery"

func printUsageError(_ errors: [String]) -> Never {
    FileHandle.standardError.write((heading + "\n\n" + "ERROR(S):\n" + errors.map { "  \($0)" }.joined(separator: "\n") + "\n\n" + helpText).data(using: .utf8)!)
    exit(1)
}

func parseArguments(_ args: [String]) -> Options {
    var o = Options()
    var errors: [String] = []
    var i = 0

    func value(_ name: String) -> String? {
        if i + 1 < args.count {
            i += 1
            return args[i]
        }
        errors.append("Option '\(name)' has no value.")
        return nil
    }

    func intValue(_ name: String) -> Int? {
        guard let v = value(name) else { return nil }
        guard let n = Int(v) else {
            errors.append("Option '\(name)' is defined with a bad format.")
            return nil
        }
        return n
    }

    while i < args.count {
        var arg = args[i]
        var inline: String?
        if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
            inline = String(arg[arg.index(after: eq)...])
            arg = String(arg[..<eq])
        }

        func next(_ name: String) -> String? {
            if let inline { return inline }
            return value(name)
        }

        switch arg {
        case "-i", "--input": o.inputPath = next("i, input")
        case "-o", "--output": o.outputPath = next("o, output")
        case "-l", "--level":
            if let inline { o.compressionLevel = Int(inline) ?? 5 } else if let n = intValue("l, level") { o.compressionLevel = n }
        case "-r", "--recursive": o.recursive = true
        case "-d", "--discs": o.discs = next("d, discs")
        case "-v", "--verbosity":
            if let inline { o.verbosity = Int(inline) ?? 3 } else if let n = intValue("v, verbosity") { o.verbosity = n }
        case "-x": o.overwriteIfExists = true
        case "-s", "--skip": o.skipIfExists = true
        case "-f", "--format": if let f = next("f, format") { o.fileNameFormat = f }
        case "-g", "--log": o.log = true
        case "--extract": o.extractResources = true
        case "--import": o.importResources = true
        case "--generate": o.generateResourceFolders = true
        case "--resource-format": o.resourceFormat = next("resource-format")
        case "--resource-root": o.resourceRoot = next("resource-root")
        case "--help", "-h", "-?":
            print(heading + "\n\n" + helpText)
            exit(0)
        case "--version":
            print("PSXPackager \(PSXPackagerVersion.string)")
            exit(0)
        default:
            errors.append("Option '\(arg.trimmingCharacters(in: CharacterSet(charactersIn: "-")))' is unknown.")
        }
        i += 1
    }

    if o.inputPath == nil {
        errors.append("At least one option from group 'input' (i, input) is required.")
    }

    if !errors.isEmpty {
        printUsageError(errors)
    }

    return o
}

// MARK: - Terminal helpers

/// Reads a single key press without waiting for Return.
func readKey() -> Character? {
    var original = termios()
    let isTerminal = tcgetattr(STDIN_FILENO, &original) == 0

    if isTerminal {
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }
    defer {
        if isTerminal { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
    }

    var byte: UInt8 = 0
    let n = read(STDIN_FILENO, &byte, 1)
    if n <= 0 { return nil }
    let c = Character(UnicodeScalar(byte))
    print(c, terminator: "")
    return c
}

func write(_ text: String) {
    print(text, terminator: "")
    fflush(stdout)
}

func timestamp(_ date: Date = Date()) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
    return String(format: "[%02d:%02d:%02d]: ", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
}

func elapsedText(_ start: Date) -> (hours: String, minutes: Int, seconds: Int) {
    let elapsed = Date().timeIntervalSince(start)
    let totalSeconds = Int(elapsed)
    return (String(format: "%02.0f", elapsed / 3600), (totalSeconds / 60) % 60, totalSeconds % 60)
}

// MARK: - Notifiers

final class ConsoleNotifier: Notifier {
    private var total: Double = 0
    private var lastUpdate = Date.distantPast
    private var charsToDelete = 0
    private let logLevel: Int
    private var startDateTime = Date()

    init(logLevel: Int) {
        self.logLevel = logLevel
    }

    private func level(_ event: PopstationEvent) -> Int {
        switch event {
        case .processingStart, .processingComplete, .error: return -1
        case .warning: return 1
        case .info: return 3
        case .fileName: return 0
        case .getIsoSize, .convertSize, .extractSize, .writeSize: return -1
        case .convertStart, .discStart, .extractStart, .decompressStart,
             .convertProgress, .extractProgress, .writeProgress, .decompressProgress,
             .convertComplete, .extractComplete, .discComplete, .decompressComplete:
            return 2
        default: return -1
        }
    }

    private func stamp(_ event: PopstationEvent) -> String {
        if logLevel < 4 || event.isProgressEvent { return "" }
        return timestamp()
    }

    private func writeLine(_ event: PopstationEvent, _ text: String) {
        print(stamp(event) + text)
    }

    private func writeText(_ event: PopstationEvent, _ text: String) {
        write(stamp(event) + text)
    }

    private var lastText = ""

    private func overwrite(_ text: String) {
        if text == lastText && charsToDelete > 0 { return }
        lastText = text
        write(String(repeating: "\u{8}", count: charsToDelete) + text)
        charsToDelete = text.count
    }

    func notify(_ event: PopstationEvent, _ value: Any?) {
        if level(event) > logLevel { return }

        switch event {
        case .processingStart:
            startDateTime = Date()
            let c = Calendar.current.dateComponents([.hour, .minute, .second], from: startDateTime)
            writeLine(event, String(format: "Processing started: %02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0))

        case .processingComplete:
            let e = elapsedText(startDateTime)
            writeLine(event, "Processing completed: \(e.hours)h \(String(format: "%02d", e.minutes))m \(String(format: "%02d", e.seconds))s")

        case .error:
            charsToDelete = 0
            writeLine(event, "\n\(value.map { "\($0)" } ?? "")")

        case .fileName, .info:
            writeLine(event, "\(value.map { "\($0)" } ?? "")")

        case .warning:
            // Dark yellow, as the original
            writeLine(event, "\u{1B}[33mWARNING: \(value.map { "\($0)" } ?? "")\u{1B}[0m")

        case .getIsoSize, .convertSize, .extractSize, .writeSize:
            total = numericValue(value)

        case .convertStart:
            writeText(event, "Converting Disc \(value.map { "\($0)" } ?? "") - ")
        case .discStart:
            writeText(event, "Writing Disc \(value.map { "\($0)" } ?? "") - ")
        case .extractStart:
            writeText(event, "Extracting Disc \(value.map { "\($0)" } ?? "") - ")
        case .decompressStart:
            writeText(event, "Decompressing file \(value.map { "\($0)" } ?? "") - ")

        case .convertComplete:
            break

        case .extractComplete, .discComplete, .decompressComplete:
            overwrite("100%")
            charsToDelete = 0
            print("")

        case .convertProgress, .extractProgress, .writeProgress:
            if Date().timeIntervalSince(lastUpdate) > 0.01 {
                let percent = total > 0 ? (numericValue(value) / total * 100).rounded() : 0
                overwrite("\(Int(percent))%")
                lastUpdate = Date()
            }

        case .decompressProgress:
            if Date().timeIntervalSince(lastUpdate) > 0.01 {
                overwrite("\(value.map { "\($0)" } ?? "")%")
                lastUpdate = Date()
            }

        default:
            break
        }
    }
}

final class LogNotifier: Notifier {
    private let path: String
    private var startDateTime = Date()

    init(path: String) {
        self.path = path
    }

    private func writeLine(_ event: PopstationEvent, _ text: String) {
        let line = (event.isProgressEvent ? "" : timestamp()) + text + "\r\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    func notify(_ event: PopstationEvent, _ value: Any?) {
        let text = value.map { "\($0)" } ?? ""
        switch event {
        case .processingStart:
            startDateTime = Date()
            let c = Calendar.current.dateComponents([.hour, .minute, .second], from: startDateTime)
            writeLine(event, String(format: "Processing started: %02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0))
        case .processingComplete:
            let e = elapsedText(startDateTime)
            writeLine(event, "Processing completed in \(e.hours)h \(String(format: "%02d", e.minutes))m \(String(format: "%02d", e.seconds))s")
        case .error: writeLine(event, "ERROR: \(text)")
        case .info: writeLine(event, "INFO: \(text)")
        case .warning: writeLine(event, "WARNING: \(text)")
        case .convertStart: writeLine(event, "Converting Disc \(text)")
        case .discStart: writeLine(event, "Writing Disc \(text)")
        case .extractStart: writeLine(event, "Extracting Disc \(text)")
        case .decompressStart: writeLine(event, "Decompressing file \(text)")
        default: break
        }
    }
}

final class ConsoleEventHandler: EventHandler {
    var cancelled = false
    var overwriteIfExists = false

    func actionIfFileExists(_ path: String) -> ActionIfFileExists {
        while true {
            write("\n\(path) alreasy exists. Overwrite? (Y)es|(N)o|(A)ll|(C)ancel ")
            let key = readKey()
            print("")

            switch key.map({ Character($0.lowercased()) }) {
            case "y"?:
                return .overwrite
            case "n"?:
                return .skip
            case "a"?:
                overwriteIfExists = true
                return .overwriteAll
            case "c"?:
                cancelled = true
                return .abort
            case nil:
                // No terminal to ask: behave as Cancel
                cancelled = true
                return .abort
            default:
                continue
            }
        }
    }
}

// MARK: - File matching

func containsWildCards(_ name: String) -> Bool {
    name.contains("?") || name.contains("*")
}

func pathIsDirectory(_ path: String) -> Bool {
    if containsWildCards(path) { return false }
    return PathUtil.directoryExists(path)
}

let supportedFiles = [".rar", ".zip", ".tar", ".gz", ".7z", ".bin", ".cue", ".img", ".chd", ".pbp"]

func filesFromDirectory(_ path: String, _ filterExpression: String?, _ recursive: Bool) -> [String] {
    let expression = (filterExpression?.isEmpty ?? true) ? supportedFiles.joined(separator: ";") : filterExpression!
    let filters = expression.split(whereSeparator: { $0 == ";" || $0 == "|" }).map(String.init)

    var results: [String] = []
    let fm = FileManager.default

    for filter in filters {
        let pattern = filter.hasPrefix(".") ? "*\(filter)" : filter

        let items = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
        for item in items {
            let full = PathUtil.combine(path, item)
            guard PathUtil.fileExists(full) else { continue }
            if fnmatch(pattern.lowercased(), item.lowercased(), 0) == 0 &&
                supportedFiles.contains(PathUtil.lowerExtension(full)) {
                results.append(full)
            }
        }

        if recursive {
            for item in items {
                let full = PathUtil.combine(path, item)
                if PathUtil.directoryExists(full) {
                    results.append(contentsOf: filesFromDirectory(full, expression, recursive)
                        .filter { supportedFiles.contains(PathUtil.lowerExtension($0)) })
                }
            }
        }
    }

    return results
}

// MARK: - Main

let cancellation = CancellationToken()

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigintSource.setEventHandler {
    if !cancellation.isCancellationRequested {
        print("Stopping...")
        cancellation.cancel()
    }
}
sigintSource.resume()

let tempPath = AppPaths.tempDirectory

var o = parseArguments(Array(CommandLine.arguments.dropFirst()))

print("PSXPackager v\(PSXPackagerVersion.string) by RupertAvery\n")

if o.compressionLevel < 0 || o.compressionLevel > 9 {
    print("Invalid compression level, please enter a value from 0 to 9")
    exit(Results.ok)
}

if let discs = o.discs, !discs.isEmpty {
    if !Regex1(#"\d(,\d)*"#).isMatch(discs) {
        print("Invalid discs specification, please enter a comma separated list of values from 1-5")
        exit(Results.ok)
    }
}

if let input = o.inputPath, !input.isEmpty {
    print("Input : \(input)")
}

if o.outputPath?.isEmpty ?? true {
    if let input = o.inputPath, !input.isEmpty {
        o.outputPath = PathUtil.directoryName(input)
    }
}

print("Output: \(o.outputPath ?? "")")
print("Compression Level: \(o.compressionLevel)")

if o.overwriteIfExists {
    print("WARNING: You have chosen to overwrite all files in the output directory!")
}

let resourceOptionsCount = (o.extractResources ? 1 : 0) + (o.importResources ? 1 : 0) + (o.generateResourceFolders ? 1 : 0)

if resourceOptionsCount > 1 {
    print("Invalid option, please select only one of extract, import, or generate")
    exit(Results.ok)
}

if o.resourceFormat?.isEmpty ?? true {
    if o.extractResources || o.importResources {
        o.resourceFormat = "%FILENAME%/%RESOURCE%.%EXT%"
    } else if o.generateResourceFolders {
        o.resourceFormat = "%FILENAME%"
    }
}

print("")

var files: [String] = []

if let input = o.inputPath, !input.isEmpty {
    if pathIsDirectory(input) {
        files.append(contentsOf: filesFromDirectory(input, nil, o.recursive))
    } else {
        let filename = PathUtil.fileName(input)
        let path = PathUtil.directoryName(input)
        if !path.isEmpty && pathIsDirectory(path) && containsWildCards(filename) {
            files.append(contentsOf: filesFromDirectory(path, filename, o.recursive))
        } else if containsWildCards(filename) {
            files.append(contentsOf: filesFromDirectory(".", filename, o.recursive))
        } else {
            files.append(input)
        }
    }
}

let discs: [Int] = (o.discs?.isEmpty ?? true)
    ? [1, 2, 3, 4, 5]
    : o.discs!.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

let options = ProcessOptions()
options.files = files
options.outputPath = o.outputPath ?? ""
options.tempPath = tempPath
options.discs = discs
options.checkIfFileExists = !o.overwriteIfExists
options.skipIfFileExists = o.skipIfExists
options.fileNameFormat = o.fileNameFormat
options.compressionLevel = o.compressionLevel
options.verbosity = o.verbosity
options.log = o.log
options.extractResources = o.extractResources
options.importResources = o.importResources
options.generateResourceFolders = o.generateResourceFolders
options.resourceFormat = o.resourceFormat ?? ""
options.resourceRoot = o.resourceRoot ?? ""

func processFiles(_ options: ProcessOptions) -> Int32 {
    var result = Results.ok

    let eventHandler = ConsoleEventHandler()
    let notifier = AggregateNotifier()
    notifier.add(ConsoleNotifier(logLevel: options.verbosity))

    if options.log {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-hhmmss"
        notifier.add(LogNotifier(path: formatter.string(from: Date()) + ".log"))
    }

    let gameDb = GameDB()
    let processing = Processing(notifier: notifier, eventHandler: eventHandler, gameDb: gameDb)

    notifier.notify(.processingStart, nil)

    if options.files.isEmpty {
        notifier.notify(.error, "No files matched!")
        result = Results.error
    } else if options.files.count > 1 {
        notifier.notify(.info, "Matched \(options.files.count) files")

        var i = 1
        for file in options.files {
            if !PathUtil.fileExists(file) {
                notifier.notify(.error, "Could not find file '\(file)'")
                continue
            }

            notifier.notify(.info, "Processing \(i) of \(options.files.count)")
            notifier.notify(.fileName, "Processing \(file)")

            _ = processing.processFile(file, options: options, cancellation: cancellation)

            if cancellation.isCancellationRequested || eventHandler.cancelled {
                result = Results.cancelled
                break
            }

            i += 1
        }

        notifier.notify(.info, "\(i - 1) files processed")
    } else {
        let file = options.files[0]

        if !PathUtil.fileExists(file) {
            notifier.notify(.error, "Could not find file '\(file)'")
            return Results.invalidInput
        }

        notifier.notify(.fileName, "Processing \(file)")

        let processResult = processing.processFile(file, options: options, cancellation: cancellation)

        result = processResult ? Results.ok : (cancellation.isCancellationRequested ? Results.cancelled : Results.error)
    }

    notifier.notify(.processingComplete, nil)

    return result
}

exit(processFiles(options))
