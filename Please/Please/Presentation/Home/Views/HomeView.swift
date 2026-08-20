//
//  HomeView.swift
//  Please
//
//  Created by 길지훈 on 8/12/26.
//

import SwiftUI

/// 홈 화면 — 사인 세션 시작의 진입점.
/// v0.1 스코프: 세션 시작 + 모드 선택 (PLANNING.md 화면 #2)
struct HomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "hand.draw")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Please!")
                    .font(.largeTitle.bold())

                NavigationLink("사인 세션 시작") {
                    SigningSessionView()
                }
                .buttonStyle(.glassProminent)
            }
            .padding()
        }
    }
}

#Preview {
    HomeView()
}
