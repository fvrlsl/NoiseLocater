import SwiftUI
import SwiftData

/// 主导航
struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            TaskListView()
                .tabItem { Label("任务", systemImage: "list.bullet.rectangle") }
                .tag(0)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(1)
        }
    }
}

// MARK: - 任务列表
struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskModel.createdAt, order: .reverse) private var tasks: [TaskModel]
    @State private var showingCreate = false

    var body: some View {
        NavigationStack {
            List {
                if tasks.isEmpty {
                    ContentUnavailableView(
                        "暂无任务",
                        systemImage: "waveform",
                        description: Text("点击右上角创建新任务")
                    )
                } else {
                    ForEach(tasks) { task in
                        NavigationLink(destination: TaskDetailView(task: task)) {
                            TaskRowView(task: task)
                        }
                    }
                    .onDelete(perform: deleteTask)
                }
            }
            .navigationTitle("噪声排查")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingCreate) {
                TaskCreateView()
            }
        }
    }

    private func deleteTask(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(tasks[index])
        }
        try? modelContext.save()
    }
}

// MARK: - 任务行
struct TaskRowView: View {
    let task: TaskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.name).font(.headline)
                Spacer()
                StatusBadge(status: task.status)
            }
            HStack {
                Text(task.layoutMode == .planar ? "平面" : "立体")
                Text("·")
                Text("\(task.activePoints.count)点位")
                Text("·")
                Text(String(format: "初始 %.1fm", task.spacing))
            }
            .font(.caption)
            .foregroundColor(.secondary)
            Text(task.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct StatusBadge: View {
    let status: TaskStatus

    var body: some View {
        Text(status == .inProgress ? "进行中" : "已完成")
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(status == .inProgress ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
            .foregroundColor(status == .inProgress ? .blue : .green)
            .clipShape(Capsule())
    }
}

// MARK: - 创建任务
struct TaskCreateView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var layoutMode: LayoutMode = .planar
    @State private var spacing: Double = 1.5
    @State private var bandMode: BandMode = .multi
    @State private var singleBand = FrequencyBand.low.name
    @State private var showSaveError = false
    @State private var saveError = ""

    private let spacingOptions: [Double] = [1.0, 1.5, 2.0]

    var body: some View {
        NavigationStack {
            Form {
                Section("任务信息") {
                    TextField("任务名称", text: $name)
                }

                Section("点位布局") {
                    Picker("布局模式", selection: $layoutMode) {
                        Text("平面（2D）").tag(LayoutMode.planar)
                        Text("立体（3D）").tag(LayoutMode.volumetric)
                    }

                    Picker("间距", selection: $spacing) {
                        ForEach(spacingOptions, id: \.self) { d in
                            Text(String(format: "%.1f m", d)).tag(d)
                        }
                    }
                }

                Section("检测频段") {
                    Picker("频段模式", selection: $bandMode) {
                        Text("多频段").tag(BandMode.multi)
                        Text("单频段").tag(BandMode.single)
                    }
                    if bandMode == .single {
                        Picker("分析频段", selection: $singleBand) {
                            ForEach(FrequencyBand.all, id: \.name) { band in
                                Text(band.title).tag(band.name)
                            }
                        }
                    }
                    Text("用于筛选排查候选；不限制录音和完整频谱的保存。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新建任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { createTask() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("创建失败", isPresented: $showSaveError) {
                Button("确定", role: .cancel) {}
            } message: { Text(saveError) }
        }
    }

    private func createTask() {
        let task = TaskModel(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            layoutMode: layoutMode,
            spacing: spacing,
            bandMode: bandMode,
            selectedBands: bandMode == .multi ? ["low", "mid", "high"] : [singleBand]
        )
        task.points = LayoutFactory.generatePoints(layout: layoutMode, spacing: spacing)
        for point in task.points { point.task = task }
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        context.insert(task)
        do {
            try context.save()
            dismiss()
        } catch {
            context.rollback()
            saveError = error.localizedDescription
            showSaveError = true
        }
    }
}

// MARK: - 设置
struct SettingsView: View {
    @AppStorage("captureDuration") private var captureDuration = 8.0
    @AppStorage("refreshInterval") private var refreshInterval = 1.0
    @AppStorage("anomalyThreshold") private var anomalyThreshold = 6.0
    @AppStorage("saveAudio") private var saveAudio = true
    @AppStorage("aWeighting") private var aWeighting = false
    @AppStorage("showHarmonics") private var showHarmonics = true
    @AppStorage("showRefLines") private var showRefLines = true
    @AppStorage("genVolume") private var genVolume = -20.0
    @AppStorage("genDuration") private var genDuration = 3.0

    var body: some View {
        NavigationStack {
            Form {
                Section("采集") {
                    HStack {
                        Text("采集时长")
                        Spacer()
                        Picker("", selection: $captureDuration) {
                            Text("5s").tag(5.0)
                            Text("8s").tag(8.0)
                            Text("10s").tag(10.0)
                            Text("15s").tag(15.0)
                            Text("30s").tag(30.0)
                        }
                    }
                    HStack {
                        Text("刷新间隔")
                        Spacer()
                        Picker("", selection: $refreshInterval) {
                            Text("0.5s").tag(0.5)
                            Text("1s").tag(1.0)
                            Text("2s").tag(2.0)
                            Text("5s").tag(5.0)
                        }
                    }
                    Toggle("保存录音（无损 PCM）", isOn: $saveAudio)
                    Text("频谱始终保存；关闭录音后无法回放或从原始音频重新分析。")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("频谱计权", value: "未计权")
                }

                Section("检测") {
                    HStack {
                        Text("异常阈值")
                        Spacer()
                        Picker("", selection: $anomalyThreshold) {
                            Text("3 dB").tag(3.0)
                            Text("6 dB").tag(6.0)
                            Text("9 dB").tag(9.0)
                            Text("12 dB").tag(12.0)
                        }
                    }
                    Toggle("低频谐波标记", isOn: $showHarmonics)
                    Toggle("低频参考线", isOn: $showRefLines)
                }

                Section("音频生成") {
                    HStack {
                        Text("默认音量")
                        Spacer()
                        Text("\(Int(genVolume)) dB FS")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $genVolume, in: -40.0 ... -10.0) {
                        Text("音量")
                    }
                    HStack {
                        Text("默认时长")
                        Spacer()
                        Picker("", selection: $genDuration) {
                            Text("1s").tag(1.0)
                            Text("3s").tag(3.0)
                            Text("5s").tag(5.0)
                            Text("10s").tag(10.0)
                        }
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}
