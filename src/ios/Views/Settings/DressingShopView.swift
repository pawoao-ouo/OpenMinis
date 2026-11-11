import SwiftUI

/// 临时空壳：旧装扮页的前端已清除，主题服务、存储和所有用户数据均保留。
/// 新界面等醒醒确认视觉方向后再接回。
struct DressingShopView: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppearanceBackdrop(scope: .global))
            .navigationTitle(AppLocalized("装扮"))
        .navigationBarTitleDisplayMode(.large)
    }
}
