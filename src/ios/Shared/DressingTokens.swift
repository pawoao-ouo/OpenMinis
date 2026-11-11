import SwiftUI

/// 装扮中心（DressingShopView.swift 里主页面 + 各 Dressing* 抽屉）的
/// 圆角、边距、阴影统一变量。
///
/// 之前这些值全是散在文件里的字面量，改一处要满文件找；
/// 现在按角色收进这里，改一处只改一行。
///
/// 所有 token 的值都照搬今天文件里用的那个数，只改名字不改数，
/// 渲染结果和改前逐像素一致。算出来的圆角（气泡半径、预览圆角）
/// 不在这里——那是运行时算的值，换不了名。
///
/// 用法和 CSSThemeVariables 同一套：enum + static 值。
enum DressingTokens {
    /// 圆角：按表面角色分。
    enum Radius {
        /// 默认卡片（主页面和各抽屉里最常见的卡）。
        static let card: CGFloat = 16
        /// 卡片里的子卡 / 行。
        static let innerCard: CGFloat = 14
        /// 大卡：透光卡、bento 卡。
        static let largeCard: CGFloat = 18
        /// 实时预览 dock 的外框。
        static let previewDock: CGFloat = 20
        /// 64px 壁纸缩略图、保存主题弹窗的输入框。
        static let field: CGFloat = 12
        /// 小块面 / 小按钮（符号格、图标槽、输入框）。
        static let chip: CGFloat = 10
        /// 取色格。
        static let swatch: CGFloat = 8
        /// 28px 装饰缩略图。
        static let thumbnail: CGFloat = 6
    }

    /// 边距：全边。
    enum Padding {
        /// 标准卡片内边距。
        static let card: CGFloat = 12
        /// 抽屉正文内边距。
        static let sheet: CGFloat = 16
        /// 大卡内边距、抽屉里的区块内边距。
        static let section: CGFloat = 14
        /// 小容器内边距。
        static let inner: CGFloat = 8
        /// 很小的容器内边距。
        static let tiny: CGFloat = 6
        /// 内层卡片的内边距（挂件卡）。
        static let innerCard: CGFloat = 10
        /// 图标按钮的点击热区（垃圾桶）。
        static let tapTarget: CGFloat = 4
        /// 分段胶囊（自动 / 日间 / 夜间那排）的内边距。
        static let segment: CGFloat = 3

        /// 页面 / 抽屉的横向外边距。
        static let page: CGFloat = 16
        /// 卡片的横向内边距。
        static let cardHorizontal: CGFloat = 14
        /// 内容行的横向内边距。
        static let contentHorizontal: CGFloat = 12
        /// 胶囊（pill）的横向内边距。
        static let pillHorizontal: CGFloat = 10
        /// 密集行的横向内边距。
        static let rowHorizontal: CGFloat = 8
        /// 卡片头小胶囊的横向内边距（预设卡、作曲图标卡）。
        static let headerPillHorizontal: CGFloat = 7
        /// 条目小胶囊的横向内边距（挂件、图标槽、分类符号）。
        static let itemPillHorizontal: CGFloat = 6

        /// 卡片的纵向内边距。
        static let cardVertical: CGFloat = 10
        /// 区块的纵向内边距（空态文案、保存弹窗）。
        static let sectionVertical: CGFloat = 12
        /// 颜色角色行的纵向内边距（那行比别的行高一档）。
        static let tallRowVertical: CGFloat = 9
        /// 内容行的纵向内边距。
        static let contentVertical: CGFloat = 8
        /// 字体胶囊按钮的纵向内边距。
        static let capsuleButtonVertical: CGFloat = 7
        /// 宽胶囊的纵向内边距。
        static let widePillVertical: CGFloat = 6
        /// 胶囊（pill）的纵向内边距。
        static let pillVertical: CGFloat = 5
        /// 行的纵向内边距。
        static let rowVertical: CGFloat = 4
        /// 小胶囊的纵向内边距。
        static let smallPillVertical: CGFloat = 3

        /// 抽屉头部的上边距。
        static let sheetTop: CGFloat = 14
        /// 区块的上边距。
        static let sectionTop: CGFloat = 8
        /// 壁纸小字说明的上边距（只是一点小上移）。
        static let labelTop: CGFloat = 2
        /// 抽屉头部的下边距。
        static let sheetBottom: CGFloat = 8
        /// 底部留白：浮动保存按钮离底边的距离。
        static let scrollBottom: CGFloat = 24
    }

    /// 阴影：两套配方。
    enum Shadow {
        /// 浮动保存按钮的阴影。
        static let floatingColor: Color = .black.opacity(0.18)
        static let floatingRadius: CGFloat = 8
        static let floatingY: CGFloat = 4

        /// 选中态的阴影：选中才有，没选中是透明。
        static func selectedColor(isSelected: Bool) -> Color {
            isSelected ? .black.opacity(0.06) : .clear
        }
        static let selectedRadius: CGFloat = 3
        static let selectedY: CGFloat = 1
    }
}
