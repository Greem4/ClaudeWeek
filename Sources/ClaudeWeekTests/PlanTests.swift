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

    // Сутки календарные, поэтому окно ПТ 15:00 → ПТ 15:00 режется на восемь:
    // 9 часов вечера пятницы, шесть полных суток, 15 часов её утра.
    t.suite("план: накопительный ряд") {
        let row = window.days.map { Int($0.planPercent.rounded()) }
        t.equal(row, [10, 24, 38, 53, 67, 81, 96, 100], "к концу последних суток — ровно 100 %")
        // Полные сутки идут ровно по 13 рабочих часов — те самые «14 % в день».
        t.close(window.planPercent(forDay: 2) - window.planPercent(forDay: 1),
                100 * 13 / 91, "полные сутки весят одинаково")
        // За час до сброса план почти сто: остаток догорит сам.
        t.close(window.planPercent(at: at(2026, 8, 14, 14, 0)), 100 * 90 / 91,
                "за час до сброса план — 99 %")
    }

    // Ряд на панели: пятница одной строкой, и до 100 % неделю доводит она же.
    t.suite("план: ряд панели") {
        let midweek = window.rows(at: at(2026, 8, 9, 12, 0)).map { Int($0.planPercent.rounded()) }
        t.equal(midweek, [10, 24, 38, 53, 67, 81, 96],
                "пока неделя катится, ряд заканчивается четвергом на 96 %")

        let lastDay = window.rows(at: at(2026, 8, 14, 9, 0)).map { Int($0.planPercent.rounded()) }
        t.equal(lastDay, [24, 38, 53, 67, 81, 96, 100],
                "в последние сутки пятница встаёт в конец и добирает остаток")

        // Обе половины пятницы вместе весят столько же, сколько полные сутки.
        t.close(window.planPercent(forDay: 0), 100 * 9 / 91, "вечер пятницы — 9 из 91 часа")
        t.close(100 - window.planPercent(forDay: 6), 100 * 4 / 91, "её утро — оставшиеся 4")
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
        t.equal(m.state, .normal, "70 % — обгон плана виден темпом, но цвет спокойный")

        // Лимит кончится там, где прогноз пересечёт 100 %: план в этот момент
        // равен доле уже потраченного — 100/1.4 от недели.
        if let exhaustion = m.exhaustionDate {
            t.close(window.planPercent(at: exhaustion), 100 * 100 / 140,
                    "момент исчерпания", tolerance: 0.05)
            t.check(window.contains(exhaustion), "и он внутри окна")
        } else {
            t.fail("ждали дату исчерпания лимита")
        }

        // Ниже жёлтого порога: 45 % при плане 50 %.
        let calm = UsageSnapshot.make(
            usedPercent: 45, cumulativeByDay: [], window: window,
            source: .official, fetchedAt: now, isEstimate: false
        )
        t.equal(calm.state(), .normal, "45 % — спокойно")
        t.check(calm.metrics(at: now).exhaustionDate == nil, "в графике лимит не кончится")

        // Пороги берутся включительно: настроенные 81 % загораются ровно на 81.
        let warning = UsageSnapshot.make(
            usedPercent: 81, cumulativeByDay: [], window: window,
            source: .official, fetchedAt: now, isEstimate: false
        )
        t.equal(warning.state(), .warning, "81 % — жёлтый ровно на пороге")

        // Первый рабочий час новой недели: план околонулевой, и три процента
        // обгоняют его в разы. Цвет при этом обязан остаться спокойным.
        let justAfterReset = window.date(atProgress: 0.01)
        let earlyBurst = UsageSnapshot.make(
            usedPercent: 3, cumulativeByDay: [], window: window,
            source: .official, fetchedAt: justAfterReset, isEstimate: false
        )
        t.equal(earlyBurst.state(), .normal, "3 % сразу после сброса — не тревога")
        t.check(earlyBurst.metrics(at: justAfterReset).burnRate ?? 0 > 1,
                "…хотя темп честно показывает обгон плана")

        // Пороговые состояния.
        let critical = UsageSnapshot.make(
            usedPercent: 96, cumulativeByDay: [], window: window,
            source: .official, fetchedAt: now, isEstimate: false
        )
        t.equal(critical.state(), .critical, "96 % — лимит на исходе")
        t.equal(critical.state(thresholds: Thresholds(weekWarn: 20, weekCritical: 99)), .warning,
                "свои пороги двигают ту же лестницу")

        let exhausted = UsageSnapshot.make(
            usedPercent: 100, cumulativeByDay: [], window: window,
            source: .official, fetchedAt: now, isEstimate: false
        )
        t.equal(exhausted.state(), .exhausted, "100 % — лимит исчерпан")
        t.close(exhausted.metrics(at: now).remainingPercent, 0, "остаток не уходит в минус")

        // Сессия живёт своей лестницей: неделя спокойна, а сессия уже красная.
        let session = SessionUsage(usedPercent: 96, resetsAt: now.addingTimeInterval(3600))
        t.equal(session.state(), .critical, "96 % сессии — красная")
        t.equal(calm.state(), .normal, "…при спокойной неделе рядом")
        t.equal(SessionUsage(usedPercent: 79, resetsAt: now).state(), .normal,
                "79 % сессии — ещё спокойно")

        // Сразу после сброса плана ещё нет — темп неопределён, а не бесконечен.
        let fresh = UsageSnapshot.make(
            usedPercent: 0, cumulativeByDay: [], window: window,
            source: .official, fetchedAt: window.start, isEstimate: false
        )
        let freshMetrics = fresh.metrics(at: window.start)
        t.check(freshMetrics.burnRate == nil, "темп в момент сброса не считается")
        t.check(freshMetrics.projectedPercent == nil, "прогноз в момент сброса не считается")
        t.equal(freshMetrics.state, .normal, "после сброса — спокойно")
    }

    // Ряд от понедельника живёт в своей шкале: 100 % в нём — это не весь
    // недельный лимит, а то, что осталось к утру понедельника.
    t.suite("строки дней: шкала от понедельника") {
        let window = WeekWindow(containing: at(2026, 8, 9, 12, 0), config: config(weekStart: .monday))
        let now = at(2026, 8, 11, 12, 0)
        // Факт по суткам окна: к концу воскресенья съедено 45 % недели.
        let snapshot = UsageSnapshot.make(
            usedPercent: 52,
            cumulativeByDay: [10, 25, 45, 52, nil, nil, nil, nil],
            window: window,
            source: .local,
            fetchedAt: now,
            isEstimate: true
        )
        let rows = snapshot.rows(at: now)
        t.equal(rows.map(\.index), [3, 4, 5, 6, 7, 1, 2], "ряд от понедельника, выходные за скобкой")

        // Остаток к утру понедельника — 55 % недели. Понедельник съел из него
        // 52 − 45 = 7, то есть 12,7 % остатка.
        t.close(rows[0].usedPercent ?? 0, 100 * 7 / 55, "факт понедельника — доля остатка")
        t.close(rows[0].planPercent, 100 * 13 / 56, "и план его суток — тоже")
        t.equal(rows[1].usedPercent, nil, "будущие сутки по-прежнему без факта")

        // Выходные остались в недельной шкале: они и правда съели свою долю
        // лимита, и пересчитывать её не на что.
        t.close(rows[5].usedPercent ?? 0, 25, "суббота — накопительный процент недели")
        t.close(rows[6].usedPercent ?? 0, 45, "воскресенье — тоже")

        // Лимит, сожжённый до понедельника, делить не на что.
        let burnt = UsageSnapshot.make(
            usedPercent: 100,
            cumulativeByDay: [40, 70, 100, 100, nil, nil, nil, nil],
            window: window,
            source: .local,
            fetchedAt: now,
            isEstimate: true
        )
        t.close(burnt.rows(at: now)[0].usedPercent ?? 0, 100, "неделя без остатка — строка полная")
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
        t.equal(snapshot.byDay.count, 8, "восемь суток: сброс делит пятницу надвое")
        t.equal(snapshot.byDay[0].usedPercent, 10, "факт первых суток")
        t.equal(snapshot.byDay[4].usedPercent, nil, "будущие сутки без факта")
        t.close(snapshot.byDay[3].overspendPercent, 70 - 100 * 48 / 91, "перерасход четвёртых суток")
        t.close(snapshot.byDay[0].overspendPercent, 10 - 100 * 9 / 91, "перерасход первых суток")
        t.close(snapshot.byDay[1].overspendPercent, 25 - 100 * 22 / 91, "перерасход вторых суток")
        t.close(snapshot.byDay[4].overspendPercent, 0, "у будущих суток перерасхода нет")

        // Половины дня сброса помечены: подпись дня у них та же, что у полных
        // суток, а часов меньше.
        t.check(snapshot.byDay[0].isPartial, "вечер пятницы — обрезанные сутки")
        t.check(snapshot.byDay[7].isPartial, "утро пятницы — тоже")
        t.check(!snapshot.byDay[1].isPartial, "суббота — полные сутки")

        // На панель из восьми суток идут семь: пятница одна.
        let rows = snapshot.rows(at: now)
        t.equal(rows.count, 7, "строк на панели семь")
        t.equal(rows.map(\.index), [0, 1, 2, 3, 4, 5, 6], "среди недели — вечер пятницы и до четверга")
        t.equal(snapshot.rows(at: at(2026, 8, 14, 9, 0)).map(\.index), [1, 2, 3, 4, 5, 6, 7],
                "в последние сутки — от субботы до утра пятницы")
        t.equal(snapshot.rows(at: at(2026, 8, 14, 9, 0)).last?.usedPercent, nil,
                "факт последней строки берётся у её же суток")
    }
}
