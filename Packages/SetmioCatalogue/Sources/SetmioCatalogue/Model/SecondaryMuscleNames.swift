import Foundation

/// Chinese names for the free-form words upstream uses in `secondaryMuscles`. Written for Setmio; it is not upstream data.
/// `SecondaryMuscleNamesTests` checks that every word in the bundled library has an entry, so a data update that adds a
/// new word fails loudly instead of quietly showing English.
public enum SecondaryMuscleNames {
    public static let zh: [String: String] = [
        "core": "核心肌群",
        "shoulders": "肩部",
        "glutes": "臀肌",
        "hamstrings": "腘绳肌",
        "triceps": "肱三头肌",
        "hip flexors": "髋屈肌",
        "obliques": "腹斜肌",
        "quadriceps": "股四头肌",
        "forearms": "前臂",
        "upper back": "上背部",
        "lower back": "下背部",
        "calves": "小腿",
        "biceps": "肱二头肌",
        "rhomboids": "菱形肌",
        "trapezius": "斜方肌",
        "rear deltoids": "三角肌后束",
        "upper chest": "上胸",
        "chest": "胸肌",
        "adductors": "内收肌",
        "lats": "背阔肌",
        "grip muscles": "握力肌群",
        "ankles": "踝部",
        "lower abs": "下腹",
        "rotator cuff": "肩袖肌群",
        "brachialis": "肱肌",
        "feet": "足部",
        "soleus": "比目鱼肌",
        "shins": "胫骨前肌",
        "wrist flexors": "腕屈肌",
        "groin": "腹股沟",
        "inner thighs": "大腿内侧",
        "sternocleidomastoid": "胸锁乳突肌",
        "wrist extensors": "腕伸肌",
        "hands": "手部",
        "traps": "斜方肌",
        "deltoids": "三角肌",
        "back": "背部",
        "latissimus dorsi": "背阔肌",
        "ankle stabilizers": "踝部稳定肌",
        "wrists": "腕部",
        "abdominals": "腹肌",
    ]

    /// The Chinese name for an upstream word, or the word itself when there is no entry.
    public static func name(_ word: String, in language: CatalogueLanguage) -> String {
        switch language {
        case .zh: zh[word] ?? word
        default: word
        }
    }
}
