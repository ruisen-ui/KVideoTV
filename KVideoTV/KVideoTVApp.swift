//
//  KVideoTVApp.swift
//  KVideoTV
//
//  KVideo 的 Apple TV (tvOS) 原生客户端。
//
//  注：tvOS 不提供 WebKit.framework，无法使用 WKWebView，
//  因此这里不是网页壳，而是直接对接采集源的原生实现。
//  详见 ContentView.swift 顶部的说明。
//

import SwiftUI

@main
struct KVideoTVApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
