import Foundation
import PSXCore

enum TrackStatus { case stopped, playing }

final class Track: ObservableObject, Identifiable {
    let id = UUID()
    @Published var status: TrackStatus = .stopped
    @Published var isSelected = false
    let number: Int
    let dataType: String
    let cueTrack: CueTrack

    init(_ track: CueTrack) {
        number = track.number
        dataType = track.dataType
        cueTrack = track
    }

    var isAudio: Bool { dataType.uppercased() == "AUDIO" }
}

final class Disc: ObservableObject, Identifiable {
    let id = UUID()
    var index: Int
    @Published var title = ""
    @Published var gameID = ""
    @Published var region = ""
    @Published var size: UInt32 = 0
    @Published var isEmpty = true
    @Published var isRemoveEnabled = false
    @Published var isLoadEnabled = true
    @Published var isSaveAsEnabled = false
    @Published var tracks: [Track] = []
    var sourceUrl: String?
    var sourceTOC: String?

    init(index: Int) {
        self.index = index
    }

    static func empty(_ index: Int) -> Disc {
        Disc(index: index)
    }

    /// "Title (12.34MB)" or "No disc loaded".
    var information: String {
        if isEmpty { return "No disc loaded" }
        return String(format: "%@ (%.2fMB)", title, Double(size) / 1_048_576)
    }
}

enum SFOEntryType { case bin, str, num }

final class SFOEntryModel: ObservableObject, Identifiable {
    let id = UUID()
    let key: String
    @Published var value: String {
        didSet { validate() }
    }
    @Published var isEditable = true
    @Published var isValid = true
    var maxLength = 0
    var entryType: SFOEntryType = .str
    var toolTip = ""
    var validator: ((String) -> Bool)? {
        didSet { validate() }
    }

    init(key: String, value: String, isEditable: Bool = true) {
        self.key = key
        self.value = value
        self.isEditable = isEditable
    }

    private func validate() {
        if let validator {
            isValid = validator(value)
        }
    }

    /// The value as it goes into PARAM.SFO.
    var sfoValue: SFOValue {
        if entryType == .num, let i = Int(value.trimmingCharacters(in: .whitespaces)) {
            return .int(i)
        }
        return .string(value)
    }
}
