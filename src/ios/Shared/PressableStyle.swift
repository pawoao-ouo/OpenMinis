//
//  PressableStyle.swift
//  MinisApp
//
//  [T-35] 店外的按压反馈。
//
//  装扮店里的按钮早就接上了 FontPressStyle，店外 166 处 `.buttonStyle(.plain)`
//  按下去什么都不发生 —— 点着没手感，还以为没点上。这个样式就是店外那一份：
//  按下缩一点点，松手弹回去，别的什么都不改。
//
//  两条护栏：
//   1. 尊重「减弱动态效果」。开了就不缩放，只留一个极轻的透明度变化，
//      免得动效成了负担。
//   2. 只加手感，不加布局。它不改尺寸、不改内边距、不拦截手势，
//      所以放在 ScrollView / List 里的按钮照样能滚 —— 它只是在按下时
//      给 label 一个 transform。
//

import SwiftUI

struct PressableStyle: ButtonStyle {
    /// 按下时缩到多少。0.96 是「有反应但不跳」的那一档。
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, scale: scale)
    }
}

private struct PressableBody: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            // 减弱动态效果时留一点可感知的反馈，但不做位移动画。
            .opacity(configuration.isPressed && reduceMotion ? 0.72 : 1)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.08)
                    : .timingCurve(0.22, 1, 0.36, 1, duration: 0.15),
                value: configuration.isPressed
            )
    }
}
