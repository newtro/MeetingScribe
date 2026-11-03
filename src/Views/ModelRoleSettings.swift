import SwiftUI

struct ModelRoleSettings: View {
    let role: ModelRole
    let title: String
    @State private var model = ""
    @State private var effort = "medium"
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).frame(width: 125, alignment: .leading)
                TextField("Model ID", text: $model).onSubmit(save)
                Picker("Effort", selection: $effort) {
                    Text("Low").tag("low"); Text("Medium").tag("medium"); Text("High").tag("high")
                }.labelsHidden().frame(width: 95).onChange(of: effort) { _, _ in if !model.isEmpty { save() } }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.onAppear {
            let setting = ModelPolicy.setting(for: role)
            model = setting.modelID; effort = setting.effort
        }
    }
    private func save() {
        var setting = ModelPolicy.setting(for: role)
        setting.modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        setting.effort = effort
        do { try ModelPolicy.save(setting, for: role); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
