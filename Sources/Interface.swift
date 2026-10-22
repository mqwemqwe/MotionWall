import SwiftUI
import AVKit

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 32)).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MotionWall").font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("Твоё видео — живые обои.").foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(model.preferences.enabled && !model.effectivePaused ? Color.mint : Color.secondary).frame(width: 7, height: 7)
                    Text(model.preferences.enabled ? "Включено" : "Выключено").font(.caption)
                }.padding(10).background(.white.opacity(0.06), in: Capsule())
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.55))
                if let player = model.preview {
                    VideoPlayer(player: player).clipShape(RoundedRectangle(cornerRadius: 18))
                } else {
                    VStack(spacing: 13) {
                        Image(systemName: "film.stack").font(.system(size: 46, weight: .light)).foregroundStyle(.mint)
                        Text("Начни с любимого видео").font(.title3.weight(.semibold))
                        Text("MP4 · MOV · MKV · AVI · WebM · и другие")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Выбрать видео") { model.chooseMovie() }.buttonStyle(.borderedProminent).tint(.mint)
                            .disabled(model.busy)
                    }
                }
                if model.busy {
                    RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.78))
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(model.status).font(.headline)
                        Text("Окно можно закрыть — обработка продолжится.").font(.caption).foregroundStyle(.secondary)
                        if model.importing { Button("Отменить") { model.cancelImport() } }
                    }
                }
            }.frame(height: 278)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selected?.title ?? "Видео пока не выбрано").font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(model.selected.map { "\(Int($0.seconds)) сек · без звука · бесконечный повтор" } ?? "Видео обрабатывается на твоём Mac")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Выбрать другое…") { model.chooseMovie() }.disabled(model.busy)
            }

            VStack(spacing: 14) {
                HStack {
                    Label("Масштаб", systemImage: "arrow.up.left.and.arrow.down.right")
                    Spacer()
                    Picker("Масштаб", selection: Binding(get: { model.preferences.fill }, set: model.setFill)) {
                        Text("Заполнить экран").tag(true)
                        Text("Видео целиком").tag(false)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 285)
                }
                Toggle("Показывать на всех мониторах", isOn: Binding(get: { model.preferences.allScreens }, set: model.setAllScreens))
                Toggle("Пауза в режиме энергосбережения macOS", isOn: Binding(get: { model.preferences.respectLowPower }, set: model.setLowPower))
                Toggle("Запускать при входе в систему", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                if model.loginNeedsApproval {
                    Button("Разрешить автозапуск в настройках macOS…") { model.openLoginSettings() }.font(.caption)
                }
            }.toggleStyle(.switch).controlSize(.small)
                .padding(18).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                .disabled(model.restoring || model.installingSaver)

            VStack(alignment: .leading, spacing: 12) {
                Label("Блокировка и видеозаставка", systemImage: "lock.rectangle").font(.headline)
                Text("Установи заставку и выбери MotionWall в настройках macOS (в новых версиях: Обои → Заставка). Для блокировки включи запрос пароля «Немедленно».")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(model.saverInstalled ? "Обновить видеозаставку…" : "Установить видеозаставку…") {
                        model.installScreenSaver()
                    }.disabled(model.selected == nil || model.busy)
                    Button("Настройки заставки") { model.openScreenSaverSettings() }
                    Button("Пароль и экран") { model.openLockSettings() }
                }
                Text("В заставку копируется выбранное видео с текущим масштабом. После смены видео или масштаба нажми «Обновить видеозаставку».")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.saverMessage {
                    Text(message).font(.callout).foregroundStyle(.mint).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HStack {
                    Button("Запустить заставку macOS") { model.startScreenSaver() }
                        .disabled(!model.saverInstalled || model.busy)
                    Spacer()
                    Button(model.awakeUntil == nil ? "Не гасить экран 30 минут" : "Разрешить выключение экрана") {
                        model.toggleKeepAwake()
                    }
                }
                if let until = model.awakeUntil {
                    Text("Экран останется включённым до \(until, style: .time), пока работает MotionWall.")
                        .font(.caption).foregroundStyle(.mint)
                }
                Text("Запускается заставка, выбранная в macOS. При вводе пароля появляется стандартный экран системы. Сон и закрытие крышки выключают экран. Режим на 30 минут удобнее использовать от сети.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(18).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))

            HStack {
                Button { model.install() } label: {
                    Label("Установить обои", systemImage: "desktopcomputer").padding(.horizontal, 10)
                }.buttonStyle(.borderedProminent).tint(.mint).controlSize(.large)
                    .disabled(model.selected == nil || model.busy)
                Button(model.preferences.paused ? "Продолжить" : "Пауза") { model.togglePause() }
                    .disabled(!model.preferences.enabled)
                Spacer()
                Button("Убрать обои") { model.removeWallpaper() }.disabled(!model.preferences.enabled)
            }
            Text(model.status + " · Закрой окно — управление останется в строке меню.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(28).frame(width: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .alert("MotionWall", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Понятно", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}
