import Foundation
import SwiftData

@Model
final class MeasurePoint {
    var id: UUID = UUID()
    var order: Int = 0
    var name: String = ""
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0
    var task: TaskModel?
    var deletedAt: Date? = nil

    @Relationship(deleteRule: .cascade, inverse: \Recording.point)
    var recordings: [Recording] = []

    init(order: Int, name: String, x: Double, y: Double, z: Double = 0) {
        self.id = UUID()
        self.order = order
        self.name = name
        self.x = x
        self.y = y
        self.z = z
        self.recordings = []
    }

    var coordinate: (x: Double, y: Double, z: Double) {
        (x, y, z)
    }
}

enum LayoutFactory {
    static func generatePoints(layout: LayoutMode, spacing: Double) -> [MeasurePoint] {
        let d = spacing
        switch layout {
        case .planar:
            return [
                MeasurePoint(order: 1, name: "1", x: 0, y: 0),
                MeasurePoint(order: 2, name: "2", x: d, y: 0),
                MeasurePoint(order: 3, name: "3", x: 0, y: d),
                MeasurePoint(order: 4, name: "4", x: d, y: d),
            ]
        case .volumetric:
            return [
                MeasurePoint(order: 1, name: "1", x: 0, y: 0, z: 0),
                MeasurePoint(order: 2, name: "2", x: d, y: 0, z: 0),
                MeasurePoint(order: 3, name: "3", x: 0, y: d, z: 0),
                MeasurePoint(order: 4, name: "4", x: d, y: d, z: 0),
                MeasurePoint(order: 5, name: "5", x: 0, y: 0, z: d),
                MeasurePoint(order: 6, name: "6", x: d, y: 0, z: d),
                MeasurePoint(order: 7, name: "7", x: 0, y: d, z: d),
                MeasurePoint(order: 8, name: "8", x: d, y: d, z: d),
            ]
        }
    }
}
