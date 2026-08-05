import Foundation
import ClaudeWeekCore

func runPlanTests(_ t: Harness) {
    let window = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config())

    t.suite("план: непрерывная линия") {
        t.close(window.planPercent(at: window.start), 0, "в момент сброса план нулевой")
        t.close(window.planPercent(at: window.end), 100, "к следующему сбросу план — 100 %")
        t.close(window.planPercent(at: window.start.addingTimeInterval(window.duration / 2)),
                50, "в середине недели — половина")
        t.close(window.planPercent(at: window.start.addingTimeInterval(-3600)),
                0, "до начала окна план не уходит в минус")
        t.close(window.planPercent(at: window.end.addingTimeInterval(3600)),
                100, "после конца окна план не превышает 100")
    }

    // Сутки календарные, поэтому окно ПТ 15:00 → ПТ 15:00 режется на восемь
    // строк: 9 часов вечера пятницы, шесть полных суток, 15 часов её утра.
    t.suite("план: ряд midDay") {
        let row = window.days.map { Int($0.planPercent.rounded()) }
        t.equal(row, [3, 13, 27, 41, 55, 70, 84, 96], "ряд по календарным суткам")
        t.close(window.planPercent(forDay: 0, anchor: .midDay), 100 * 4.5 / 168,
                "первые сутки коротки: план считается по часам, а не по номеру строки")
    }

    t.suite("план: ряд endOfDay") {
        let row = (0..<window.slotCount).map {
            Int(window.planPercent(forDay: $0, anchor: .endOfDay).rounded())
        }
        t.equal(row, [5, 20, 34, 48, 63, 77, 91, 100], "к концу последней строки — ровно 100 %")
        // То, ради чего план считается временем: в пятницу за час до сброса
        // он ещё не сто, но уже почти — 99 % в этот момент идут вровень.
        t.close(window.planPercent(at: at(2026, 8, 14, 14, 0)), 100 * 167 / 168,
                "за час до сброса план — 99 %")
    }

    t.suite("план: anchor из конфига") {
        let midDay = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config(anchor: .midDay))
        let endOfDay = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config(anchor: .endOfDay))
        t.close(midDay.days[3].planPercent, 100 * 69 / 168, "midDay: середина понедельника")
        t.close(endOfDay.days[endOfDay.slotCount - 1].planPercent, 100,
                "endOfDay: последняя строка — 100 %")
    }

    t.suite("метрики") {
        // Половина недели прожита, потрачено 70 % — обгоняем план в 1.4 раза.
        let now = window.start.addingTimeInterval(window.duration / 2)
        let snapshot = UsageSnapshot.make(
            usedPercent: 70,
            cumulativeByDay: [10, 25, 45, 70, nil, nil, nil],
            window: window,
            source: .local,
            fetchedAt: now,
            isEstimate: true
        )
        let m = snapshot.metrics(at: now)
        t.close(m.remainingPercent, 30, "осталось 30 %")
        t.close(m.planNowPercent, 50, "план на сейчас — 50 %")
        t.close(m.burnRate ?? 0, 1.4, "темп 1.4× плана")
        t.close(m.projectedPercent ?? 0, 140, "к сбросу натечёт 140 %")
        t.close(m.timeLeft, window.duration / 2, "до сброса — половина недели")
        t.equal(m.state, .overPlan, "состояние: обгоняем план")

        // Лимит кончится там, где линейный прогноз пересечёт 100 %.
        if let exhaustion = m.exhaustionDate {
            t.close(exhaustion.timeIntervalSince(window.start),
                    window.duration * 100 / 140, "момент исчерпания")
        } else {
            t.fail("ждали дату исчерпания лимита")
        }

        // В графике: 45 % при плане 50 %.
        let onTrack = UsageSnapshot.make(
            usedPercent: 45, cumulativeByDay: [], window: window,
            source: .official, fetchedAt: now, isEstimate: false
        )
        t.equal(onTrack.state(at: now), .onTrack, "45 % при плане 50 % — в графике")
        t.check(onTrack.metrics(at: now).exhaustionDate == nil, "в графике лимит не кончится")

        // Пороговые состояния.
        let critical = UsageSnapshot.make(
            usedPercent: 92, cumulativeByDay: [], window: window,
            source: .official, fetchedAt: now, isEstimate: false
        )
        t.equal(critical.state(at: now), .critical, "92 % — лимит на исходе")

        let exhausted = UsageSnapshot.make(
            usedPercent: 100, cumulativeByDay: [], window: window,
            source: .official, fetchedAt: now, isEstimate: false
        )
        t.equal(exhausted.state(at: now), .exhausted, "100 % — лимит исчерпан")
        t.close(exhausted.metrics(at: now).remainingPercent, 0, "остаток не уходит в минус")

        // Сразу после сброса плана ещё нет — темп неопределён, а не бесконечен.
        let fresh = UsageSnapshot.make(
            usedPercent: 0, cumulativeByDay: [], window: window,
            source: .official, fetchedAt: window.start, isEstimate: false
        )
        let freshMetrics = fresh.metrics(at: window.start)
        t.check(freshMetrics.burnRate == nil, "темп в момент сброса не считается")
        t.check(freshMetrics.projectedPercent == nil, "прогноз в момент сброса не считается")
        t.equal(freshMetrics.state, .onTrack, "после сброса — в графике")
    }

    t.suite("строки дней") {
        let now = window.start.addingTimeInterval(window.duration / 2)
        let snapshot = UsageSnapshot.make(
            usedPercent: 70,
            cumulativeByDay: [10, 25, 45, 70, nil, nil, nil, nil],
            window: window,
            source: .local,
            fetchedAt: now,
            isEstimate: true
        )
        t.equal(snapshot.byDay.count, 8, "восемь строк: сброс делит пятницу надвое")
        t.equal(snapshot.byDay[0].usedPercent, 10, "факт первых суток")
        t.equal(snapshot.byDay[4].usedPercent, nil, "будущие сутки без факта")
        t.close(snapshot.byDay[3].overspendPercent, 70 - 100 * 69 / 168, "перерасход четвёртых суток")
        t.close(snapshot.byDay[0].overspendPercent, 10 - 100 * 4.5 / 168, "перерасход первых суток")
        t.close(snapshot.byDay[1].overspendPercent, 25 - 100 * 21 / 168, "перерасход вторых суток")
        t.close(snapshot.byDay[4].overspendPercent, 0, "у будущих суток перерасхода нет")

        // Обрезанные сутки помечены: подпись дня у них та же, что у полных,
        // и без пометки панель показала бы две неразличимые пятницы.
        t.check(snapshot.byDay[0].isPartial, "вечер пятницы — обрезанные сутки")
        t.check(snapshot.byDay[7].isPartial, "утро пятницы — тоже")
        t.check(!snapshot.byDay[1].isPartial, "суббота — полные сутки")
    }
}
