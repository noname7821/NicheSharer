import SwiftUI

struct ReceiverView: View {
    @State private var code = ""
    @State private var sharing = false
    @State private var busy = false
    @State private var notice = ""
    @State private var serverURL = UserDefaults.standard.string(forKey: "NicheShareServer")
        ?? "https://nichesharer.onrender.com"

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("NicheShare")
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(.purple)
                    .padding(.top, 30)

                Text(sharing ? code.isEmpty ? "••••••" : code : "Not sharing")
                    .font(.system(size: 56, weight: .800, design: .monospaced))
                    .padding(.vertical, 10)

                HStack(spacing: 10) {
                    Circle()
                        .fill(sharing ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if sharing {
                    Button("Stop sharing") { stop() }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                        .disabled(busy)
                } else {
                    Button("Start sharing") { pair() }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(busy)
                }

                if !notice.isEmpty {
                    Text(notice)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Signaling server")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("https://…", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Save server") {
                        UserDefaults.standard.set(serverURL, forKey: "NicheShareServer")
                        notice = "Saved. Pair again to use it."
                    }
                    .font(.footnote)
                }
                .padding()
            }
            .padding()
            .navigationTitle("Receiver")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: refresh)
        }
        .navigationViewStyle(.stack)
    }

    private var statusText: String {
        if busy { return "Working…" }
        return sharing ? "PC can connect with this code" : "Tweak runs in SpringBoard"
    }

    private func pair() {
        busy = true
        notice = ""
        DaemonClient.send(["cmd": "pair", "server": serverURL]) { reply in
            busy = false
            if let reply = reply, reply["ok"] as? Bool == true, let c = reply["code"] as? String {
                code = c
                sharing = true
                notice = "Enter this code on the PC viewer."
            } else {
                let err = (reply?["error"] as? String) ?? "Tweak not reachable. Installed + respring done?"
                notice = err
            }
        }
    }

    private func stop() {
        busy = true
        DaemonClient.send(["cmd": "stop"]) { _ in
            busy = false
            sharing = false
            code = ""
            notice = ""
        }
    }

    private func refresh() {
        DaemonClient.send(["cmd": "status"]) { reply in
            if let reply = reply, reply["ok"] as? Bool == true {
                sharing = (reply["sharing"] as? Bool) ?? false
                code = (reply["code"] as? String) ?? ""
            }
        }
    }
}
