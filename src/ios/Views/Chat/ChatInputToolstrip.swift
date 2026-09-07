import SwiftUI
import UIKit

/// 输入栏上方的快捷工具行——kelivo `ChatInputSection` 的对应物。
///
/// 布局：一条 44pt 高的水平行，图标按钮（32×32）站在最左，间距 12。
/// 一次性接口：外界传入若干 `ChatToolstripItem`（图标 / 选中态 / 点击回调），
/// 顺序即显示序，该 view 不掌握任何业务知识，不读 store。
/// 样式对齐 AppearanceStudio scope=.chat 的 token，不硬编码色。
struct ChatToolstripItem: Identifiable {
    let id: String
    let systemImage: String
    /// 选中态（icon 变 accent，按钮描边带强调）。nil = 该按钮不支持选中态。
    var isSelected: Bool? = nil
    /// 辅助点标（右上角 4pt 小圆点，用于"有未读/有提醒"这类）。nil = 不显示。
    var showDot: Bool = false
    var action: () -> Void
}

struct ChatInputToolstrip: View {
    let items: [ChatToolstripItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(items) { item in
                    Button(action: item.action) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(
                                item.isSelected == true
                                    ? ChatColors.accent
                                    : ChatColors.secondaryText
                            )
                            .frame(width: 32, height: 32)
                            .background(
                                ChatColors.inputIconBg
                                    .opacity(item.isSelected == true ? 0.9 : 1)
                            )
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(
                                        item.isSelected == true
                                            ? ChatColors.accent.opacity(0.55)
                                            : ChatColors.inputIconBorder,
                                        lineWidth: 0.5
                                    )
                            )
                            .overlay(alignment: .topTrailing) {
                                if item.showDot {
                                    Circle()
                                        .fill(ChatColors.accent)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 1, y: -1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(item.id))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
    }
}
