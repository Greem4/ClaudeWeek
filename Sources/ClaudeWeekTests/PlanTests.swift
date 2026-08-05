import Foundation
import ClaudeWeekCore

func runPlanTests(_ t: Harness) {
    let window = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config())

    t.suite("план: непрерывная линия") {
        t.close(window.planPercent(at: window.start), 0, "в момент сброса план нулевой")
        t.close(window.planPercent(at: window.end), 100, "к следующему сбросу план — 100 %")
        t.close(window.planPercent(at: window.date(atProgress: 0.5)),
                50, "на середине рабочего времени — половина", tolerance: 0.05)
        t.close(window.planPercent(at: window.start.addingTimeInterval(-3600)),
                0, "до начала окна план не уходит в минус")
        t.close(window.planPercent(at: window.end.addingTimeInterval(3600)),
                100, "после конца окна план не превышает 100")
    }

    // Рабочий день по умолчанию — 11:00…00:00. Окно ПТ 15:00 → ПТ 15:00 даёт
    // 9 рабочих часов в вечер пятницы, по 13 в полные сутки и 4 в её утро:
    // 91 час, по которым и раскладываются 100 %.
    t.suite("план: рабочие часы") {
        t.close(window.planPercent(at: at(2026, 8, 8, 3, 0)),
                window.planPercent(at: at(2026, 8, 8, 11, 0)),
                "ночью план стоит: в три часа и в одиннадцать он один и тот же")
        t.close(window.planPercent(at: at(2026, 8, 7, 24, 0)), 100 * 9 / 91,
                "вечер пятницы после сброса — девять рабочих часов")
        t.close(window.planPercent(at: at(2026, 8, 14, 15, 0)) - window.planPercent(at: at(2026, 8, 14, 0, 0)),
                100 * 4 / 91, "утро пятницы до сброса — четыре")

        // Круглосуточный режим возвращает прежнюю линейную шкалу.
        let allDay = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config(work: WorkHours(start: 0, end: 24)))
        t.close(allDay.planPercent(at: allDay.start.addingTimeInterval(allDay.duration / 2)),
                50, "круглосуточно — ровно половина в середине недели")

        // Момент, к которому план дорастёт до доли: обратная к `progress`.
        let half = window.date(atProgress: 0.5)
        t.check(window.contains(half), "середина рабочей недели внутри окна")
        t.close(window.progress(at: half), 0.5, "и это действительно её середина", tolerance: 0.001)
    }

    // Сутки календарные, поэтому окно ПТ 15:00 → ПТ 15:00 режется на восемь
    // строк: 9 часов вечера пятницы, шесть полных суток, 15 часов её утра.
    t.suite("план: ряд midDay") {
        let row = window.days.map { Int($0.planPercent.rounded()) }
        t.equal(row, [5, 17, 31, 46, 60, 74, 88, 98], "ряд по рабочим часам суток")
        t.close(window.planPercent(forDay: 0, anchor: .midDay), 100 * 4.5 / 91,
                "середина строки — половина её рабочего времени, а не полдень")
    }

    t.suite("план: ряд endOfDay") {
        let row = (0..<window.slotCount).map {
            Int(window.planPercent(forDay: $0, anchor: .endOfDay).rounded())
        }
        t.equal(row, [10, 24, 38, 53, 67, 81, 96, 100], "к концу последней строки — ровно 100 %")
        // Полные сутки идут ровно по 13 рабочих часов — те самые «14 % в день».
        t.close(window.planPercent(forDay: 2, anchor: .endOfDay) - window.planPercent(forDay: 1, anchor: .endOfDay),
                100 * 13 / 91, "полные сутки весят одинаково")
        // За час до сброса план почти сто: остаток догорит сам.
        t.close(window.planPercent(at: at(2026, 8, 14, 14, 0)), 100 * 90 / 91,
                "за час до сброса план — 99 %")
    }

    t.suite("план: anchor из конфига") {
        let midDay = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config(anchor: .midDay))
        let endOfDay = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config(anchor: .endOfDay))
        t.close(midDay.days[3].planPercent, 100 * 41.5 / 91, "midDay: середина понедельника")
        t.close(endOfDay.days[endOfDay.slotCount - 1].planPercent, 100,
                "endOfDay: последняя строка — 100 %")
    }

    t.suite("метрики") {
        // Половина рабочей недели прожита, потрачено 70 % — обгоняем план
        // в 1.4 раза. Момент берём у самого окна: с рабочими часами середина
        // недели уже не совпадает с серединой календарного отрезка.
        let now = window.date(atProgress: 0.5)
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
        t.close(m.planNowPercent, 50, "план на сейчас — 50 %", tolerance: 0.05)
        t.close(m.burnRate ?? 0, 1.4, "темп 1.4× плана", tolerance: 0.002)
        t.close(m.projectedPercent ?? 0, 140, "к сбросу натечёт 140 %", tolerance: 0.2)
        t.close(m.timeLeft, window.end.timeIntervalSince(now), "до сброса — остаток окна")
        t.equal(m.state, .overPlan, "состояние: обгоняем план")

        // Лимит кончится там, где прогноз пересечёт 100 %: план в этот момент
        // равен доле уже потраченного — 100/1.4 от недели.
        if let exhaustion = m.exhaustionDate {
            t.close(window.planPercent(at: exhaustion), 100 * 100 / 140,
                    "момент исчерпания", tolerance: 0.05)
            t.check(window.contains(exhaustion), "и он внутри окна")
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
        t.close(snapshot.byDay[3].overspendPercent, 70 - 100 * 41.5 / 91, "перерасход четвёртых суток")
        t.close(snapshot.byDay[0].overspendPercent, 10 - 100 * 4.5 / 91, "перерасход первых суток")
        t.close(snapshot.byDay[1].overspendPercent, 25 - 100 * 15.5 / 91, "перерасход вторых суток")
        t.close(snapshot.byDay[4].overspendPercent, 0, "у будущих суток перерасхода нет")

        // Обрезанные сутки помечены: подпись дня у них та же, что у полных,
        // и без пометки панель показала бы две неразличимые пятницы.
        t.check(snapshot.byDay[0].isPartial, "вечер пятницы — обрезанные сутки")
        t.check(snapshot.byDay[7].isPartial, "утро пятницы — тоже")
        t.check(!snapshot.byDay[1].isPartial, "суббота — полные сутки")
    }
}
