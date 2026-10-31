import Foundation

// MARK: - Words a general speech model gets wrong in an Indian household

/// Brands, apps, foods and household words that are said every day in India and that a recogniser trained mostly on other
/// English tends to mishear ("Blinkit" as "blink it", "atta" as "alter"). Used two ways: as speech key terms, which bias
/// the decoder towards them (Whisper's `initial_prompt` and Apple Speech's `contextualStrings`), so the words reach the model right.
///
/// Spell and capitalise each exactly as it should appear. No commas: commas separate key terms.
nonisolated enum IndianVocabulary {
    /// The brands said most often: always first in the key terms, and always in the model's reference vocabulary.
    static let brands: [String] = ["Blinkit", "Swiggy", "Zomato", "Zepto", "Grofers", "UPI", "Paytm"]

    static let terms: [String] = [
        // Quick commerce, delivery and shopping
        "Blinkit", "Zepto", "Swiggy", "Instamart", "Zomato", "BigBasket", "Flipkart", "Myntra", "Meesho", "Nykaa",
        "Urban Company", "DMart", "Reliance Fresh", "JioMart", "Dunzo", "Ola", "Rapido", "IRCTC",
        // Payments, bills and services
        "Paytm", "PhonePe", "Google Pay", "BHIM", "UPI", "Jio", "Airtel", "BSNL", "Tata Power", "BESCOM", "Aadhaar", "GST", "EMI",
        // Packaged food and household brands
        "Amul", "Maggi", "Aashirvaad", "Haldiram's", "Parle-G", "Britannia", "Tata Salt", "Saffola", "Fortune", "MDH", "Everest",
        "Mother Dairy", "Nandini", "Dabur", "Patanjali", "Vim", "Surf Excel", "Harpic", "Lizol", "Dettol", "Colgate", "Bournvita",
        "Horlicks", "Kissan", "Kurkure", "Lays", "Bisleri", "Tropicana", "Real Juice",
        // Staples and kitchen words
        "atta", "paneer", "dal", "ghee", "jeera", "haldi", "besan", "sooji", "poha", "rava", "chana", "rajma", "curd", "dahi",
        "masala", "jaggery", "kirana", "sabzi", "chai", "roti", "tiffin",
        // People who help at home, and how they are addressed
        "bai", "didi", "bhaiya", "dhobi", "driver", "maid", "cook",
        // Festivals and occasions
        "Diwali", "Holi", "Rakhi", "Puja", "Navratri", "Ganesh Chaturthi"
    ]
}

// MARK: - Key terms for the recogniser

/// Builds the list handed to the speech models as key terms: the brand list first, then the household's own names (people,
/// lists, routines), then the bundled Indian brands and words. A long list costs a little accuracy on everything else, so it is capped.
nonisolated enum KeyTerms {
    static let limit = 120
    static let householdLimit = 40

    static func build(household: [String], bundled: [String] = IndianVocabulary.terms, limit: Int = KeyTerms.limit) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) -> Bool {
            let term = raw.replacingOccurrences(of: ",", with: " ")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !term.isEmpty, term.count <= 40, seen.insert(term.lowercased()).inserted else { return false }
            out.append(term)
            return true
        }
        for t in IndianVocabulary.brands where out.count < limit { _ = add(t) }
        var fromHousehold = 0
        for t in household where fromHousehold < householdLimit && out.count < limit {
            if add(t) { fromHousehold += 1 }
        }
        for t in bundled where out.count < limit { _ = add(t) }
        return out
    }
}
