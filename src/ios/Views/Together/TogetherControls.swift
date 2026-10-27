//
//  TogetherControls.swift
//  MinisApp
//
//  一起听 · 统一的按压与触感。
//
//  一处定死，六个视图共用：按下去缩 0.96 + 淡到 0.7，100–150ms，
//  只缩不移位（布局不动，手指不追按钮跑）。触感只给她亲手点的那一下，
//  AI 推过来的变化、歌词滚动、轮询刷新一律不震——震错了比不震还难受。
//

import SwiftUI
import UIKit

/// 所有一起听按钮的按压态。代替各处手写的 .buttonStyle(.plain)。
struct TogetherPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension Button {
    /// 一起听按钮的默认样式：按压态 + 不抢布局。
    func togetherPress() -> some View {
        buttonStyle(TogetherPressStyle())
    }
}

enum TogetherHaptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let light = UIImpactFeedbackGenerator(style: .light)

    /// 选了一个东西（切歌、换模式、开抽屉、点喜欢）。
    static func select() {
        selection.prepare()
        selection.selectionChanged()
    }

    /// 播/停这一类"落下去"的动作。
    static func tap() {
        light.prepare()
        light.impactOccurred()
    }
}
