import AppKit
import SwiftUI

/// 侧边栏「桌面宠物」入口：切换内置形象、管理自定义 GIF 与宠物文件夹。
struct PetManagementPage: View {
    @ObservedObject private var appearance = PetAppearance.shared
    @State private var deleteTarget: PetAsset?
    @AppStorage("pet.enabled") private var petEnabled = false
    @AppStorage("pet.tracking") private var trackingEnabled = true

    private var assets: [PetAsset] { appearance.storage.assets }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("桌面宠物").font(.title2.bold())
                    Text("内置 5 只形象开箱即用；也可以导入自己的 GIF 并框选展示区域。所有形象统一保存在本机宠物文件夹，删除自定义形象后不可恢复。")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("打开宠物文件夹", systemImage: "folder") { appearance.openFolder() }
                Button("导入 GIF…", systemImage: "square.and.arrow.down") { appearance.importGIF() }
                    .buttonStyle(.borderedProminent)
            }
            if let issue = appearance.issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 152), spacing: 12)], spacing: 12) {
                    ForEach(assets) { asset in
                        card(asset)
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            HStack(spacing: 18) {
                Toggle("在桌面显示桌宠", isOn: Binding(
                    get: { petEnabled },
                    set: { PetController.shared.setEnabled($0) }))
                Toggle("任务进度跟踪", isOn: Binding(
                    get: { trackingEnabled },
                    set: { PetController.shared.setTrackingEnabled($0) }))
                Spacer()
                Text("宠物文件夹：\(appearance.storage.directory.path)")
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .font(.system(size: 12))
            Text("悬浮播放动画，移开静止；单击桌宠回到主窗口，右键可新建对话、记录、提醒或收回宠物。")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear { appearance.refresh() }
        .alert("删除这个自定义形象？", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget { appearance.delete(target) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("GIF 会移入废纸篓。内置形象不受影响，之后仍可随时切回。")
        }
    }

    private func card(_ asset: PetAsset) -> some View {
        let selected = appearance.selectedAsset?.id == asset.id
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let preview = appearance.preview(for: asset) {
                        Image(nsImage: preview)
                            .resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: "questionmark.square.dashed")
                            .font(.system(size: 28)).foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 112)
                if selected {
                    Text("使用中").font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundColor(.white)
                }
            }
            Text(asset.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(asset.builtin?.hint ?? "自定义 GIF").font(.caption2)
                .foregroundColor(.secondary).lineLimit(1)
            HStack(spacing: 8) {
                if selected {
                    Label("当前形象", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundColor(.accentColor)
                } else {
                    Button("使用") { appearance.select(asset) }
                        .font(.caption2).buttonStyle(.borderless).foregroundColor(.accentColor)
                }
                Spacer(minLength: 0)
                if asset.isCustom {
                    Menu {
                        Button("重新框选…") { appearance.crop(asset) }
                        Button("在 Finder 中显示") { appearance.storage.reveal(asset) }
                        Button("删除…", role: .destructive) { deleteTarget = asset }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                } else {
                    Button {
                        appearance.storage.reveal(asset)
                    } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless).help("在 Finder 中显示")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(selected ? 0.08 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { appearance.select(asset) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(asset.name)，\(selected ? "当前形象" : "点击使用")")
    }
}
