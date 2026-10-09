import Foundation
import SetmioCore

/// Receives imported pages. Implemented by the app (writes to `SetmioStore`); must be idempotent on
/// `HealthSample.hkUUID` because anchors are only advanced after the sink succeeds, so a crash between the two
/// re-delivers the same page.
public protocol HealthSampleSink: Sendable {
    func ingest(_ batch: AnchoredBatch, kind: HealthMetricKind) async throws
}

/// Outcome of `HealthSampleImporter.importAll`.
public struct ImportReport: Sendable, Equatable {
    /// Samples ingested per kind (kinds that failed before ingesting anything are absent).
    public var counts: [HealthMetricKind: Int]
    /// Kinds whose import threw, with the error description.
    public var errors: [HealthMetricKind: String]
    public var startedAt: Date
    public var finishedAt: Date

    public init(counts: [HealthMetricKind: Int] = [:], errors: [HealthMetricKind: String] = [:], startedAt: Date, finishedAt: Date) {
        self.counts = counts
        self.errors = errors
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var totalImported: Int { counts.values.reduce(0, +) }
    public var failedKinds: [HealthMetricKind] { errors.keys.sorted { $0.rawValue < $1.rawValue } }
    public var succeeded: Bool { errors.isEmpty }
}

/// A snapshot of an `importAll` run, reported after every imported page (for progress UI).
public struct ImportProgress: Sendable, Equatable {
    /// The kind being imported right now.
    public var kind: HealthMetricKind
    /// 0-based position of `kind` in the run, and the number of kinds in the run.
    public var kindIndex: Int
    public var kindCount: Int
    /// Samples ingested so far across the whole run.
    public var importedSoFar: Int

    public init(kind: HealthMetricKind, kindIndex: Int, kindCount: Int, importedSoFar: Int) {
        self.kind = kind
        self.kindIndex = kindIndex
        self.kindCount = kindCount
        self.importedSoFar = importedSoFar
    }

    /// Fraction of kinds finished (the current kind counts as in progress, not done).
    public var fractionOfKindsCompleted: Double {
        kindCount > 0 ? Double(kindIndex) / Double(kindCount) : 1
    }
}

/// Pulls samples from a `HealthSampleSource` page by page and hands them to the sink.
///
/// - One kind is never imported twice concurrently: a second caller for the same kind awaits the in-flight
///   import instead of starting another.
/// - The anchor for a page is persisted only after `sink.ingest` returned without throwing.
public actor HealthSampleImporter {
    public static let defaultPageSize = 500

    private let source: any HealthSampleSource
    private let anchors: AnchorStore
    private let sink: any HealthSampleSink
    private let pageSize: Int
    private var inFlight: [HealthMetricKind: Task<Int, any Error>] = [:]

    public init(source: any HealthSampleSource, anchors: AnchorStore, sink: any HealthSampleSink, pageSize: Int = HealthSampleImporter.defaultPageSize) {
        self.source = source
        self.anchors = anchors
        self.sink = sink
        self.pageSize = max(1, pageSize)
    }

    /// Imports every kind in order, never throwing: failures are collected per kind in the report.
    /// `progress` is called at the start of every kind and after every page (including empty ones).
    public func importAll(kinds: [HealthMetricKind] = HealthMetricKind.mvp, progress: (@Sendable (ImportProgress) -> Void)? = nil) async -> ImportReport {
        var report = ImportReport(startedAt: Date(), finishedAt: Date())
        for (index, kind) in kinds.enumerated() {
            let before = report.totalImported
            progress?(ImportProgress(kind: kind, kindIndex: index, kindCount: kinds.count, importedSoFar: before))
            do {
                var onPage: (@Sendable (Int) -> Void)?
                if let progress {
                    onPage = { @Sendable importedInKind in
                        progress(ImportProgress(kind: kind, kindIndex: index, kindCount: kinds.count, importedSoFar: before + importedInKind))
                    }
                }
                report.counts[kind] = try await importNew(kind, onPage: onPage)
            } catch {
                report.errors[kind] = String(describing: error)
            }
        }
        report.finishedAt = Date()
        return report
    }

    /// Imports pages until one comes back shorter than the page size. Returns the number of samples ingested.
    @discardableResult
    public func importNew(_ kind: HealthMetricKind) async throws -> Int {
        try await importNew(kind, onPage: nil)
    }

    private func importNew(_ kind: HealthMetricKind, onPage: (@Sendable (Int) -> Void)?) async throws -> Int {
        if let running = inFlight[kind] {
            return try await running.value
        }
        let task = Task<Int, any Error> { [self] in
            try await self.runImport(kind, onPage: onPage)
        }
        inFlight[kind] = task
        defer { inFlight[kind] = nil }
        return try await task.value
    }

    /// Forgets every anchor so the next import starts from the beginning of the HealthKit store.
    public func resetAnchors() async {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        try? await anchors.resetAll()
    }

    // MARK: Internals

    private func runImport(_ kind: HealthMetricKind, onPage: (@Sendable (Int) -> Void)?) async throws -> Int {
        var anchor = await anchors.get(kind)
        var imported = 0
        var pages = 0
        while true {
            try Task.checkCancellation()
            let batch = try await source.anchoredSamples(of: kind, since: anchor, limit: pageSize)
            try await sink.ingest(batch, kind: kind)
            if batch.newAnchor != anchor {
                try await anchors.set(batch.newAnchor, for: kind)
            }
            imported += batch.samples.count
            pages += 1
            onPage?(imported)

            let fullPage = batch.samples.count >= pageSize || batch.deletedUUIDs.count >= pageSize
            let anchorAdvanced = batch.newAnchor != nil && batch.newAnchor != anchor
            anchor = batch.newAnchor ?? anchor
            // Stop on a short page; also stop if the source did not move the anchor (a misbehaving source
            // would otherwise loop forever on the same page).
            if !fullPage || !anchorAdvanced || pages >= 10_000 { break }
        }
        return imported
    }
}
