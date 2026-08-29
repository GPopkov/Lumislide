import SwiftUI
import SlideStoryModel

/// Главное окно редактора:
/// - слева список проектов (+ создание/открытие/удаление);
/// - справа сетка миниатюр текущего проекта (drag&drop reorder).
struct MainWindowView: View {
    @EnvironmentObject private var store: ProjectsStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HSplitView {
            // Левая колонка: список проектов.
            ProjectListView()
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            // Правая область: сетка миниатюр.
            if let project = store.currentProject {
                ThumbnailGridView(project: project)
                    .frame(minWidth: 600)
            } else {
                emptyState
                    .frame(minWidth: 600)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { store.addMedia() }) {
                    Label(L10n.text(.addMedia), systemImage: "plus")
                }
                .disabled(store.currentProject == nil)

                Button(action: { openProperties() }) {
                    Label(L10n.text(.properties), systemImage: "slider.horizontal.3")
                }
                .disabled(store.currentProject == nil)

                Button(action: { openPreview() }) {
                    Label(L10n.text(.preview), systemImage: "play.fill")
                }
                .disabled(store.currentProject == nil || store.currentProject?.slides.isEmpty == true)

                Button(action: { openExport() }) {
                    Label(L10n.text(.export), systemImage: "square.and.arrow.up")
                }
                .disabled(store.currentProject == nil || store.currentProject?.slides.isEmpty == true)
            }
        }
        .onDisappear {
            // Автосохранение при выходе.
            if settings.autosaveEnabled {
                try? store.saveCurrentProject()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(L10n.text(.noProjectSelected))
                .font(.title2)
            Text(L10n.text(.noProjectsYet))
                .foregroundStyle(.secondary)
            Button(L10n.text(.createNewProject)) {
                store.createNewProject()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func openProperties() {
        guard let project = store.currentProject else { return }
        AppWindowsController.openProperties(project: project, store: store)
    }

    private func openPreview() {
        guard let project = store.currentProject else { return }
        AppWindowsController.openPreview(project: project, store: store)
    }

    private func openExport() {
        guard let project = store.currentProject else { return }
        AppWindowsController.openExport(project: project)
    }
}
