import SwiftUI

/// Левая колонка главного окна: список проектов.
struct ProjectListView: View {
    @EnvironmentObject private var store: ProjectsStore
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text(.projects))
                    .font(.headline)
                Spacer()
                Button(action: { store.createNewProject() }) {
                    Label(L10n.text(.create), systemImage: "plus")
                }
                .labelStyle(.titleAndIcon)
                .help(L10n.text(.createNewProject))
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if store.projects.isEmpty {
                VStack(spacing: 6) {
                    Text(L10n.text(.noProjectsYet))
                        .foregroundStyle(.secondary)
                    Text(L10n.text(.clickPlusToCreate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedURL) {
                    ForEach(store.projects, id: \.self) { url in
                        ProjectRow(url: url, isSelected: store.currentProjectURL == url)
                            .tag(url)
                            .onTapGesture {
                                store.openProject(at: url)
                            }
                            .contextMenu {
                                Button(L10n.text(.open)) { store.openProject(at: url) }
                                Button(L10n.text(.projectProperties)) {
                                    // Свойства правят текущий проект — открываем его,
                                    // затем показываем окно свойств.
                                    store.openProject(at: url)
                                    if let project = store.currentProject {
                                        AppWindowsController.openProperties(project: project, store: store)
                                    }
                                }
                                Divider()
                                Button(L10n.text(.delete), role: .destructive) {
                                    store.deleteProject(at: url)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }

            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ProjectRow: View {
    let url: URL
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "film.stack")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    Text(modified.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}
