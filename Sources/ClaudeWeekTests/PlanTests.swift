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

    t.suite("план: ряд midDay") {
        let row = (0..<7).map { Int(window.planPercent(forDay: $0, anchor: .midDay).rounded()) }
        t.equal(row, [7, 21, 36, 50, 64, 79, 93], "совпадает с исходным скриншотом")
        t.close(window.planPercent(forDay: 0, anchor: .midDay), 100.0 * 0.5 / 7, "точное значение первых суток")
    }

    t.suite("план: ряд endOfDay") {
        let row = (0..<7).map { Int(window.planPercent(forDay: $0, anchor: .endOfDay).rounded()) }
        t.equal(row, [14, 29, 43, 57, 71, 86, 100], "совпадает с подписью «к концу дня»")
    }

    t.suite("план: anchor из конфига") {
        let midDay = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config(anchor: .midDay))
        let endOfDay = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config(anchor: .endOfDay))
        t.close(midDay.days[3].planPercent, 50, "midDay: четвёртые сутки — 50 %")
        t.close(endOfDay.days[6].planPercent, 100, "endOfDay: последние сутки — 100 %")
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
            cumulativeByDay: [10, 25, 45, 70, nil, nil, nil],
            window: window,
            source: .local,
            fetchedAt: now,
            isEstimate: true
        )
        t.equal(snapshot.byDay.count, 7, "семь строк")
        t.equal(snapshot.byDay[0].usedPercent, 10, "факт первых суток")
        t.equal(snapshot.byDay[4].usedPercent, nil, "будущие сутки без факта")
        t.close(snapshot.byDay[3].overspendPercent, 20, "перерасход четвёртых суток")
        t.close(snapshot.byDay[0].overspendPercent, 10 - 100 * 0.5 / 7, "перерасход первых суток")
        t.close(snapshot.byDay[1].overspendPercent, 25 - 100 * 1.5 / 7, "перерасход вторых суток")
        t.close(snapshot.byDay[4].overspendPercent, 0, "у будущих суток перерасхода нет")
    }
}
