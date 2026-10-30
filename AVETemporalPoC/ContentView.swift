import SwiftUI

struct ContentView: View {
    @State private var text = "Preparing diagnostic…"
    @State private var showStage9Warning = false
    @State private var isRunningStage9 = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("AVE Temporal Probe")
                    .font(.headline)
                Spacer()
                if isRunningStage9 {
                    ProgressView()
                }
            }
            .padding(.horizontal)

            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)

            Button {
                showStage9Warning = true
            } label: {
                Text(isRunningStage9 ? "Stage 9 is running…" : "Run Stage 9 (16463)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isRunningStage9)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .onAppear {
            let p = Probe.shared
            p.stage1()
            p.writeReport()
            text = p.log
        }
        .alert("Potential kernel panic", isPresented: $showStage9Warning) {
            Button("Cancel", role: .cancel) { }
            Button("Run Stage 9", role: .destructive) {
                runStage9()
            }
        } message: {
            Text("This test submits a frame using NumberOfTemporalLayers = 16463. On a vulnerable device and OS, it is expected to cause a kernel panic and restart the device. Save your work first. Compatibility is not guaranteed.")
        }
    }

    private func runStage9() {
        isRunningStage9 = true
        text += "\n\nStarting Stage 9 with N=16463…\n"

        // Run off the main thread so the UI does not freeze while VideoToolbox works.
        DispatchQueue.global(qos: .userInitiated).async {
            let probe = Probe.shared
            probe.stage9(n: 16463)
            probe.writeReport()
            let result = probe.log

            DispatchQueue.main.async {
                text = result
                isRunningStage9 = false
            }
        }
    }
}
