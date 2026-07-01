//
//  WelcomeView.swift
//  notch
//
//  Created by Richard Kunkli on 2024. 09. 26..
//

import SwiftUI
import SwiftUIIntrospect
import FluidGradient

struct WelcomeView: View {
    var onGetStarted: (() -> Void)? = nil
    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                // Replaces the old static "spotlight" image: Cindori's FluidGradient
                // (Metal/CoreAnimation-backed) renders slowly-morphing color blobs as a
                // soft glow behind the logo, masked to a circular pool so it fades into
                // the vibrancy. Same sparkles behind it as before.
                FluidGradient(
                    blobs: [.blue, .purple, .indigo, .cyan],
                    highlights: [.cyan, .white, .blue],
                    speed: 0.6,
                    blur: 0.78
                )
                .frame(width: 280, height: 280)
                .mask(
                    RadialGradient(
                        colors: [.white, .white.opacity(0.85), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 140
                    )
                )
                .opacity(0.9)
                .padding(.bottom)
                .offset(y: -5)
                .background(SparkleView().opacity(0.6))
                VStack(spacing: 8) {
                    Image("perch-owl")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .padding(.bottom, 8)
                    Text("Perch")
                        .font(.system(.largeTitle, design: .default))
                        .fontWeight(.semibold)
                    Text("Welcome")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 30)
                    if false {
                        Text("PRO")
                            .font(.system(size: 18, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.7), location: 0.3), .init(color: .clear, location: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .blendMode(.overlay)
                            )
                            .padding(.bottom, 30)
                    }


                    Button {
                        onGetStarted?()
                    } label: {
                        Text("Get started")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                }
                .padding(.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
    }
}

#Preview {
    WelcomeView()
        .frame(width: 400, height: 600)
}
