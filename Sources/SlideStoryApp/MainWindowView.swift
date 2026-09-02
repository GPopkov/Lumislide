import SwiftUI
#if canImport(_PhotosUI_SwiftUI)
import _PhotosUI_SwiftUI
#else
import PhotosUI
#endif
import SlideStoryModel

/// Главное окно редактора:
/// - слева список проектов (+ создание/открытие/удаление);
/// - справа сетка миниатюр текущего проекта (drag&drop reorder).
struct MainWindowView: View {
    @EnvironmentObject private var store: ProjectsStore
    @EnvironmentObject private var settings: AppSettings

    /// Выбранные элементы медиатеки Фото (для кнопки «Из медиатеки Фото»).
    @State private var photosItems: [PhotosPickerItem] = []

    var body: some View {
        HSplitView {
            // Левая колонка: список проектов.
            ProjectListView()
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            // Правая область: сетка миниатюр.
            if let project = store.currentProject {
                ThumbnailGridView(project: project, thumbnailSize: settings.thumbnailSize)
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
                .labelStyle(.titleAndIcon)
                .disabled(store.currentProject == nil)

                // Выбор из медиатеки Фото.
                PhotosPicker(
                    selection: $photosItems,
                    maxSelectionCount: 100,
                    matching: .any(of: [.images, .videos])
                ) {
                    Label(L10n.text(.fromPhotos), systemImage: "photo.on.rectangle.angled")
                }
                .labelStyle(.titleAndIcon)
                .disabled(store.currentProject == nil)
                .onChange(of: photosItems) { _, items in
                    guard !items.isEmpty else { return }
                    store.addPhotos(items)
                    photosItems = []
                }

                Button(action: { openProperties() }) {
                    Label(L10n.text(.properties), systemImage: "slider.horizontal.3")
                }
                .labelStyle(.titleAndIcon)
                .disabled(store.currentProject == nil)

                Button(action: { openPreview() }) {
                    Label(L10n.text(.preview), systemImage: "play.fill")
                }
                .labelStyle(.titleAndIcon)
                .disabled(store.currentProject == nil || store.currentProject?.slides.isEmpty == true)

                Button(action: { openExport() }) {
                    Label(L10n.text(.export), systemImage: "square.and.arrow.up")
                }
                .labelStyle(.titleAndIcon)
                .disabled(store.currentProject == nil || store.currentProject?.slides.isEmpty == true)
            }

            // Ползунок размера миниатюр.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                    Slider(value: $settings.thumbnailSize, in: 120...260)
                        .frame(width: 160)
                        .help(L10n.text(.thumbnailSize))
                }
            }
        }
        .onDisappear {
            // Автосохранение при выходе.
            if settings.autosaveEnabled {
                try? store.saveCurrentProject()
            }
        }
        .alert(
            L10n.text(.photosAccessDenied),
            isPresented: Binding(
                get: { store.mediaAccessError != nil },
                set: { if !$0 { store.mediaAccessError = nil } }
            )
        ) {
            Button("OK") { store.mediaAccessError = nil }
        } message: {
            Text(L10n.text(.photosAccessDeniedMessage))
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
