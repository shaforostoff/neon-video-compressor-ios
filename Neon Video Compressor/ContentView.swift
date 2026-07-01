//
//  ContentView.swift
//  Neon Video Compressor
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            SetupView()
                .navigationDestination(for: EncodeJob.self) { job in
                    ProgressView2(job: job)
                }
        }
    }
}

#Preview {
    ContentView()
}
