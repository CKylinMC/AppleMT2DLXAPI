import SwiftUI

/// 运行状态面板：每秒轮询统计数据。
struct StatusPanelView: View {
    let stats: ServerStats
    @State private var snapshot = ServerStats.Snapshot()

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                LabeledContent("在途任务", value: "\(snapshot.running)")
                LabeledContent("排队任务", value: "\(snapshot.queued)")
            }
            GridRow {
                LabeledContent("累计完成", value: "\(snapshot.completed)")
                LabeledContent("累计拒绝/失败", value: "\(snapshot.rejected + snapshot.failed)")
            }
        }
        .task {
            while !Task.isCancelled {
                snapshot = await stats.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
