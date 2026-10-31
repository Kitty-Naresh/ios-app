import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - The token budget of one flat extraction call

/// Measures the whole of a call before it is sent, and decides whether the words go in one call or in several.
///
///     projected = instructions + prompt + tools + schema + transcript + reserved output
///
/// The model counts each part itself where it can (iOS 26.4 and later); everywhere else the numbers are estimates and the trace
/// says so. A fresh session carries no transcript, and the flat path has no tools, so both are zero today and are still part of the
/// sum, so a future change cannot forget them.
struct TokenBudgetService: Equatable {
    /// Room kept for the answer. The brief asks for 800 to 1,200; 1,000 is the middle.
    static let reservedOutputTokens = 1_000

    var contextSize: Int
    var instructions: Int
    var schema: Int
    var tools = 0
    var exact: Bool
    var reserve = TokenBudgetService.reservedOutputTokens

    /// The numbers an engine reported for the extract call, with this call's own reserve.
    init(_ b: ContextBudget) {
        self.init(contextSize: b.window, instructions: b.instructions, schema: b.schema, exact: b.exact, reserve: b.reserve + b.margin)
    }

    init(contextSize: Int, instructions: Int, schema: Int, tools: Int = 0, exact: Bool, reserve: Int = TokenBudgetService.reservedOutputTokens) {
        self.contextSize = contextSize
        self.instructions = instructions
        self.schema = schema
        self.tools = tools
        self.exact = exact
        self.reserve = reserve
    }

    func projected(prompt: Int, transcript: Int = 0) -> Int { instructions + prompt + tools + schema + transcript + reserve }

    func fits(prompt: Int, transcript: Int = 0) -> Bool { projected(prompt: prompt, transcript: transcript) <= contextSize }

    /// What the prompt itself may use.
    var promptRoom: Int { max(0, contextSize - instructions - tools - schema - reserve) }

    /// The same numbers in the shape the rest of the app reads. No separate margin: the reserve is the margin.
    var contextBudget: ContextBudget {
        ContextBudget(window: contextSize, instructions: instructions, schema: schema, exact: exact, reserve: reserve, margin: 0)
    }

    var fixedLine: String {
        "window \(contextSize.formatted()) | instructions \(instructions.formatted()), schema \(schema.formatted()), tools \(tools), "
            + "answer reserve \(reserve.formatted()) | room for the prompt \(promptRoom.formatted()) | \(exact ? "counted by the model" : "estimated")"
    }

    func verdict(prompt: Int, promptExact: Bool) -> String {
        let total = projected(prompt: prompt)
        return "projected \(total.formatted()) of \(contextSize.formatted()) tokens (prompt \(prompt.formatted()) + fixed \((instructions + schema + tools).formatted()) + reserve \(reserve.formatted())) | "
            + (fits(prompt: prompt) ? "fits: one call" : "does not fit: the words are batched") + " | " + (exact && promptExact ? "counted by the model" : "estimated")
    }

    /// A budget made only of estimates, for a system that cannot count.
    static func estimated(contextSize: Int = ContextBudget.fallbackWindow) -> TokenBudgetService {
        TokenBudgetService(contextSize: max(contextSize, 1_024),
                           instructions: ContextBudget.estimate(TaskExtractionInstructions.text), schema: 450, exact: false)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    static func measure(contextSize: Int) async -> TokenBudgetService {
        var service = estimated(contextSize: contextSize)
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
            let model = SystemLanguageModel.default
            let i = try? await model.tokenCount(for: Instructions(TaskExtractionInstructions.text))
            let s = try? await model.tokenCount(for: TaskExtraction.generationSchema)
            if let i, let s {
                service.instructions = i
                service.schema = s
                service.exact = true
            }
        }
        return service
    }
    #endif
}

// MARK: - Where a request may be cut

/// How a request that must be read in more than one call is divided. Whole lists first, then whole sentences. Pieces joined are the
/// text, so nothing is truncated; a piece that cannot be made small enough is reported, never cut.
enum FlatBatcher {
    /// A header is the word "list" and a colon: "Pharmacy list: ...". A list that is named in a sentence ("add milk to my grocery
    /// list") is not a boundary.
    private static let header = try! NSRegularExpression(pattern: "\\blist\\s*:", options: [.caseInsensitive])

    /// The text divided before each explicit list header after the first, at the start of the sentence that holds it. Empty when there
    /// are fewer than two headers (one list, or none, is not divided).
    static func listSegments(_ text: String) -> [String] {
        let ns = text as NSString
        let hits = header.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard hits.count >= 2 else { return [] }
        var cuts: [Int] = []
        for hit in hits.dropFirst() {
            var i = hit.range.location
            while i > 0 {
                let c = ns.character(at: i - 1)
                if let u = Unicode.Scalar(c), ".!?;\n".unicodeScalars.contains(u) { break }
                i -= 1
            }
            while i < hit.range.location, let u = Unicode.Scalar(ns.character(at: i)), CharacterSet.whitespacesAndNewlines.contains(u) { i += 1 }
            if i > 0, !cuts.contains(i) { cuts.append(i) }
        }
        var pieces: [String] = []
        var start = 0
        for cut in cuts.sorted() where cut > start {
            pieces.append(ns.substring(with: NSRange(location: start, length: cut - start)))
            start = cut
        }
        pieces.append(ns.substring(from: start))
        return pieces.count >= 2 ? pieces : []
    }

    /// The pieces to ask for: one per explicit list when there are two or more, otherwise `[text]`.
    static func perList(_ text: String) -> [String] {
        let lists = listSegments(text)
        return lists.isEmpty ? [text] : lists
    }

    /// `text` as whole sentences packed so that each piece, with the fixed part of the call, fits. Nil when one sentence alone is
    /// too long to fit, so the caller can ask the user to continue instead of cutting it.
    static func sentenceBatches(of text: String, room: Int, charactersPerToken: Double = PromptBudget.charactersPerToken) -> [String]? {
        let limit = max(120, Int(Double(room) * charactersPerToken * 0.9))
        let pieces = PromptBudget.chunks(of: text, limit: limit)
        return pieces.allSatisfy({ $0.count <= limit }) ? pieces : nil
    }
}
