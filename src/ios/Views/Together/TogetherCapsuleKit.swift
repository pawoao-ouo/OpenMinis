//
//  TogetherCapsuleKit.swift
//  MinisApp
//
//  胶囊设计稿 1:1 零件库。数值全部照抄 胶囊设计稿.html，
//  不在这里做任何"审美判断"。
//

import SwiftUI
import UIKit

// MARK: - 变量（对应 html :root）

enum TogetherSpec {
    static let charcoal = Color(red: 0x18/255, green: 0x18/255, blue: 0x1b/255)
    static let sub      = Color(red: 0x52/255, green: 0x52/255, blue: 0x5b/255)
    static let muted    = Color(red: 0x8e/255, green: 0x8e/255, blue: 0x93/255)

    static let capsuleSurface = Color.white.opacity(0.85)
    static let capsuleBorder  = Color.white.opacity(0.95)
    static let capsuleOuter   = Color(red: 0x18/255, green: 0x18/255, blue: 0x1b/255).opacity(0.07)
}

/// 复刻 CSS 的 cubic-bezier(0.16, 1, 0.3, 1)（spring-physics 曲线）
enum TogetherCurve {
    static var springPhysics: Animation {
        .timingCurve(0.16, 1, 0.3, 1, duration: 0.45)
    }
    static var springPhysicsShort: Animation {
        .timingCurve(0.16, 1, 0.3, 1, duration: 0.4)
    }
}

// MARK: - backdrop-filter: blur() saturate()

struct TogetherBlurBackdrop: UIViewRepresentable {
    var style: UIBlurEffect.Style = .systemUltraThinMaterialLight

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

// MARK: - 唱片（Boutique Ceramic Vinyl Disc）

struct TogetherVinylDisc: View {
    var size: CGFloat = 32
    var spinning: Bool = false

    @State private var angle: Double = 0

    private var label: CGFloat { size <= 32 ? 10 : 14 }
    private var ringWidth: CGFloat { size <= 32 ? 1.5 : 1.5 }

    var body: some View {
        ZStack {
            // 盘面：同心细纹 + 径向渐变
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0x2e/255, green: 0x2e/255, blue: 0x33/255),
                            Color(red: 0x1c/255, green: 0x1c/255, blue: 0x1f/255),
                            Color(red: 0x2a/255, green: 0x2a/255, blue: 0x2e/255),
                            Color(red: 0x14/255, green: 0x14/255, blue: 0x17/255)
                        ],
                        center: .center,
                        startRadius: size * 0.1,
                        endRadius: size * 0.5
                    )
                )
            // 细纹
            ForEach(1..<6, id: \.self) { i in
                Circle()
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.6)
                    .frame(width: size * CGFloat(i) / 6.0, height: size * CGFloat(i) / 6.0)
            }
            // 中心标
            Circle()
                .fill(Color(red: 0xfa/255, green: 0xf8/255, blue: 0xf5/255))
                .frame(width: label, height: label)
                .overlay(
                    Circle().strokeBorder(Color(red: 0x1c/255, green: 0x1c/255, blue: 0x1f/255), lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.4), radius: 1.5)
            // 油光
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.4), .clear, Color.white.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: ringWidth)
        )
        .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 3)
        .rotationEffect(.degrees(angle))
        .onAppear { spinIfNeeded() }
        .onChange(of: spinning) { _ in spinIfNeeded() }
    }

    private func spinIfNeeded() {
        if spinning {
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
                angle = angle.truncatingRemainder(dividingBy: 360) + 360
            }
        } else {
            withAnimation(.linear(duration: 0)) {
                angle = angle.truncatingRemainder(dividingBy: 360)
            }
        }
    }
}

// MARK: - 律动柱（.equalizer-bars / .eq-bar）

struct TogetherEQLed: View {
    var barCount: Int = 3
    var active: Bool

    /// 每根柱子的动画时长与延迟，照抄 CSS
    private let durations: [Double] = [0.75, 0.55, 0.8]
    private let delays: [Double] = [0.0, 0.2, 0.35]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                TogetherEQBar(
                    active: active,
                    duration: durations[i % durations.count],
                    delay: delays[i % delays.count]
                )
            }
        }
        .frame(height: 14)
        .padding(.trailing, 2)
        .animation(.easeInOut(duration: 0.2), value: active)
        .accessibilityHidden(true)
    }
}

private struct TogetherEQBar: View {
    var active: Bool
    var duration: Double
    var delay: Double

    @State private var up = false

    var body: some View {
        Capsule()
            .fill(TogetherSpec.charcoal)
            .frame(width: 2, height: (active && up) ? 13 : 3)
            .opacity((active && up) ? 0.9 : 0.3)
            .onAppear { run() }
            .onChange(of: active) { _ in run() }
    }

    private func run() {
        guard active else {
            withAnimation(.easeInOut(duration: 0.2)) { up = false }
            return
        }
        up = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard active else { return }
            withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                up = true
            }
        }
    }
}