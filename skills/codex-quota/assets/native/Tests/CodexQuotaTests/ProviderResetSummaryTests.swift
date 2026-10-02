import Foundation
import QuotaCore
import XCTest
@testable import CodexQuota

final class ProviderResetSummaryTests: XCTestCase {
    // Reset dates, observations, and quota amounts are fictional test inputs.
    private let now = ISO8601DateFormatter().date(from: "2030-04-12T09:00:00Z")!

    func testCueUTCInstantDisplaysBeijingResetInsteadOfObservationTime() {
        let snapshot = ProviderSnapshot(providerID: "cue", metrics: [
            metric("weekly", "每周额度", "2030-04-16T07:22:00Z")
        ], observedAt: date("2030-04-12T09:10:00Z"))
        XCTAssertEqual(ProviderResetSummary.text(for: snapshot, now: now), "4月16日 15:22 重置")
    }

    func testUTCResetCrossesIntoTheNextBeijingDay() {
        let snapshot = ProviderSnapshot(providerID: "example", metrics: [
            metric("daily", "每日额度", "2030-04-12T16:00:00Z")
        ])
        XCTAssertEqual(ProviderResetSummary.text(for: snapshot, now: now), "4月13日 00:00 重置")
    }

    func testDayPrecisionNeverInventsAnEightAMResetTime() {
        let snapshot = ProviderSnapshot(providerID: "muse", metrics: [
            metric("weekly", "每周额度", "2030-04-19T00:00:00Z", precision: .day)
        ])
        let summary = ProviderResetSummary.summary(for: snapshot, now: now)
        XCTAssertEqual(summary.text, "4月19日重置（时间未明确）")
        XCTAssertEqual(summary.reset?.precision, .day)
        XCTAssertFalse(summary.text.contains("08:00"))
    }

    func testMultiplePrimaryCyclesChooseEarliestDocumentedResetWithItsLabel() {
        let snapshot = ProviderSnapshot(providerID: "codex", metrics: [
            metric("weekly", "每周额度", "2030-04-16T07:22:00Z", percent: 5),
            metric("short", "Codex · 5小时额度", "2030-04-12T17:00:00Z", percent: 80),
            metric("spark", "Spark", "2030-04-12T14:00:00Z", contributes: false),
            QuotaMetric(id: "balance", label: "额外额度", kind: .balance,
                        reset: QuotaReset(date: date("2030-04-12T13:00:00Z")))
        ])
        let summary = ProviderResetSummary.summary(for: snapshot, now: now)
        XCTAssertEqual(summary.text, "5小时额度 · 4月13日 01:00 重置")
        XCTAssertEqual(summary.metricLabel, "Codex · 5小时额度")
        XCTAssertEqual(summary.reset?.date, date("2030-04-12T17:00:00Z"))
    }

    func testManusDailyRefreshIsNotPresentedAsItsMissingMonthlyReset() {
        let snapshot = ProviderSnapshot(providerID: "manus", metrics: [
            QuotaMetric(id: "monthly", label: "每月积分", remaining: 4000, limit: 10000),
            metric("refresh", "每日刷新积分", "2030-04-12T16:00:00Z", contributes: false)
        ])
        let summary = ProviderResetSummary.summary(for: snapshot, now: now)
        XCTAssertEqual(summary.text, "月度重置时间未提供")
        XCTAssertNil(summary.reset)
        XCTAssertTrue(summary.detail?.contains("每月积分重置时间未提供") == true)
        XCTAssertTrue(summary.detail?.contains("每日刷新积分 · 4月13日 00:00 刷新") == true)
    }

    func testMissingResetNeverFallsBackToSnapshotObservationTime() {
        let snapshot = ProviderSnapshot(providerID: "cue", metrics: [
            QuotaMetric(id: "weekly", label: "每周额度", remainingPercent: 57)
        ], observedAt: date("2030-04-12T09:10:00Z"))
        XCTAssertEqual(ProviderResetSummary.text(for: snapshot, now: now), "重置时间未提供")
        XCTAssertNil(ProviderResetSummary.summary(for: snapshot, now: now).reset)
        XCTAssertEqual(ProviderResetSummary.text(for: nil, now: now), "等待额度数据")
    }

    func testYearUsesBeijingCalendarAndProvidedNow() {
        let beijingNewYear = date("2030-12-31T16:30:00Z")
        let sameBeijingYear = ProviderSnapshot(providerID: "example", metrics: [
            metric("weekly", "每周额度", "2031-01-01T16:00:00Z")
        ])
        XCTAssertEqual(ProviderResetSummary.text(for: sameBeijingYear, now: beijingNewYear), "1月2日 00:00 重置")
        let laterYear = ProviderSnapshot(providerID: "example", metrics: [
            metric("weekly", "每周额度", "2032-01-01T16:00:00Z")
        ])
        XCTAssertEqual(ProviderResetSummary.text(for: laterYear, now: beijingNewYear), "2032年1月2日 00:00 重置")
    }

    func testExpiredAndExactCurrentInstantDoNotLookLikeFutureResets() {
        for (reset, expected) in [("2030-04-12T08:59:00Z", "4月12日 16:59 已到重置时间"),
                                  ("2030-04-12T09:00:00Z", "4月12日 17:00 已到重置时间")] {
            let snapshot = ProviderSnapshot(providerID: "cue", metrics: [metric("weekly", "每周额度", reset)])
            XCTAssertEqual(ProviderResetSummary.text(for: snapshot, now: now), expected)
        }
    }

    func testDayPrecisionExpiresOnlyAfterItsBeijingCalendarDayHasPassed() {
        let beijingThirdDay = date("2030-04-12T17:00:00Z")
        let sameDay = ProviderSnapshot(providerID: "muse", metrics: [
            metric("weekly", "每周额度", "2030-04-13T00:00:00Z", precision: .day)
        ])
        XCTAssertEqual(ProviderResetSummary.text(for: sameDay, now: beijingThirdDay), "4月13日重置（时间未明确）")
        XCTAssertEqual(ProviderResetSummary.text(for: sameDay, now: date("2030-04-13T15:59:59Z")),
                       "4月13日重置（时间未明确）")
        XCTAssertEqual(ProviderResetSummary.text(for: sameDay, now: date("2030-04-13T16:00:00Z")),
                       "4月13日已到重置日期（时间未明确）")
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func metric(_ id: String, _ label: String, _ reset: String,
                        precision: QuotaReset.Precision = .instant, percent: Double = 57,
                        contributes: Bool = true) -> QuotaMetric {
        QuotaMetric(id: id, label: label, remainingPercent: percent,
                    reset: QuotaReset(date: date(reset), precision: precision),
                    contributesToSummary: contributes)
    }
}
