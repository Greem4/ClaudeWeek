import Foundation

/// Часы суток, по которым разложен недельный лимит.
///
/// Без них план шёл по астрономическому времени: каждый час недели весил
/// 0,6 %, и треть бюджета доставалась сну. На краях окна это видно в лоб —
/// при сбросе в 16:00 вечеру пятницы (8 часов, из них рабочие все) отводилось
/// 4,8 %, а её утру (16 часов, из них 9 — сон) вдвое больше. Считая по
/// рабочим часам, обе половины получают по своим делам: 8,8 % и 5,5 %.
///
/// Ночные часы плана не двигают вовсе. Отсюда и обратная сторона: работа в
/// три ночи ложится в перерасход целиком — плана на этот час нет.
public struct WorkHours: Codable, Sendable, Equatable, Hashable {
    /// Час начала рабочего дня, 0…23.
    public var start: Int
    /// Час конца, 1…24; 24 — полночь. Держим числом, а не датой: это правило
    /// суток, а не момент.
    public var end: Int

    public static let `default` = WorkHours(start: 11, end: 24)

    /// Готовые распорядки для выбора в настройках. Свои часы никуда не
    /// делись — степперы под списком продолжают крутить любые.
    public static let presets: [WorkHours] = [
        WorkHours(start: 10, end: 18),
        WorkHours(start: 10, end: 22),
        WorkHours(start: 11, end: 24),
        WorkHours(start: 9, end: 22),
        WorkHours(start: 0, end: 24),
    ]

    /// Название распорядка: по нему его и выбирают, а часы дописаны рядом,
    /// чтобы не гадать, что кроется за «вечерним».
    public var name: String {
        if isAllDay { return "Круглосуточно" }
        switch (start, end) {
        case (10, 18): return "Рабочий день"
        case (10, 22): return "Длинный день"
        case (11, 24): return "Вечерний"
        case (9, 22): return "С утра до ночи"
        default: return "Свои часы"
        }
    }

    /// Часы распорядка: «10–18», «11–24».
    public var range: String { "\(start)–\(end)" }

    /// Подпись для списка: «Рабочий день 10–18», «Круглосуточно».
    public var title: String {
        isAllDay ? name : "\(name) \(range)"
    }

    /// Часы словами: «10:00 – 18:00», «11:00 – полуночи».
    public var clockRange: String {
        if isAllDay { return "круглые сутки" }
        return "\(start):00 – \(end >= 24 ? "полуночи" : "\(end):00")"
    }

    public init(start: Int = 11, end: Int = 24) {
        self.start = start
        self.end = end
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WorkHours.default
        self.init(
            start: try c.decodeIfPresent(Int.self, forKey: .start) ?? d.start,
            end: try c.decodeIfPresent(Int.self, forKey: .end) ?? d.end
        )
    }

    /// Длина рабочего дня в часах.
    public var hours: Int { max(end - start, 0) }

    /// Круглосуточный режим — прежнее поведение: план растёт и ночью.
    public var isAllDay: Bool { start == 0 && end == 24 }

    public func validated() -> WorkHours {
        var w = self
        if !(0...23).contains(w.start) {
            Log.warn("workdayStart=\(w.start) вне 0…23, беру \(WorkHours.default.start)")
            w.start = WorkHours.default.start
        }
        if !(1...24).contains(w.end) {
            Log.warn("workdayEnd=\(w.end) вне 1…24, беру \(WorkHours.default.end)")
            w.end = WorkHours.default.end
        }
        // Пустой или вывернутый день оставил бы неделю вовсе без плана, и
        // делить проценты стало бы не на что: чиним на круглосуточный режим.
        if w.end <= w.start {
            Log.warn("рабочий день \(w.start)…\(w.end) пуст, считаю круглосуточно")
            w = WorkHours(start: 0, end: 24)
        }
        return w
    }

    /// Сколько рабочих секунд попадает в отрезок `[from, to)`. Отрезок может
    /// накрывать сколько угодно суток; границы дня берутся у календаря, а не
    /// прибавлением 3600 секунд, — иначе неделя с переводом часов съедет.
    func seconds(from: Date, to: Date, calendar: Calendar) -> TimeInterval {
        guard to > from else { return 0 }
        if isAllDay { return to.timeIntervalSince(from) }

        var total: TimeInterval = 0
        var midnight = calendar.startOfDay(for: from)

        // Шагов не больше, чем суток в отрезке; окно недели даёт восемь.
        while midnight < to {
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight).map({
                calendar.startOfDay(for: $0)
            }), next > midnight else { break }

            if let open = calendar.date(byAdding: .hour, value: start, to: midnight),
               let close = calendar.date(byAdding: .hour, value: end, to: midnight) {
                let lower = max(open, from)
                let upper = min(close, to)
                if upper > lower { total += upper.timeIntervalSince(lower) }
            }

            midnight = next
        }

        return total
    }
}
