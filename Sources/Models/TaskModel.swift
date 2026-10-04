import SwiftUI
import SwiftData

enum TaskStatus: String, Codable {
    case inProgress
    case completed
}

enum LayoutMode: String, Codable {
    case planar
    case volumetric
}

enum BandMode: String, Codable {
    case single
    case multi
    case custom
}

@Model
final class TaskModel {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var statusRaw: String = TaskStatus.inProgress.rawValue
    var layoutModeRaw: String = LayoutMode.planar.rawValue
    var spacing: Double = 1.5
    var bandModeRaw: String = BandMode.multi.rawValue
    var selectedBands: [String] = ["low", "mid", "high"]

    @Relationship(deleteRule: .cascade, inverse: \MeasurePoint.task)
    var points: [MeasurePoint] = []

    var activePoints: [MeasurePoint] {
        points.filter { $0.deletedAt == nil }.sorted { $0.order < $1.order }
    }

    // Convenience accessors
    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .inProgress }
        set { statusRaw = newValue.rawValue }
    }
    var layoutMode: LayoutMode {
        get { LayoutMode(rawValue: layoutModeRaw) ?? .planar }
        set { layoutModeRaw = newValue.rawValue }
    }
    var bandMode: BandMode {
        get { BandMode(rawValue: bandModeRaw) ?? .multi }
        set { bandModeRaw = newValue.rawValue }
    }

    init(name: String, layoutMode: LayoutMode = .planar,
         spacing: Double = 1.5, bandMode: BandMode = .multi,
         selectedBands: [String] = ["low", "mid", "high"]) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.statusRaw = TaskStatus.inProgress.rawValue
        self.layoutModeRaw = layoutMode.rawValue
        self.spacing = spacing
        self.bandModeRaw = bandMode.rawValue
        self.selectedBands = selectedBands
        self.points = []
    }
}
