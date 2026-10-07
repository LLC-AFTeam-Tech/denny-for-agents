import Foundation

/// What the hook prints to stdout for a PermissionRequest. `nil` means print
/// nothing and exit 0, so the agent falls back to its own terminal prompt.
public enum HookOutput {
    public static func permissionResponse(_ decision: ApprovalDecision, agent: AgentKind) -> String? {
        var decisionObject: [String: Any]
        switch decision {
        case .ask:
            return nil
        case .allow:
            decisionObject = ["behavior": "allow"]
        case .deny:
            decisionObject = ["behavior": "deny"]
            if agent == .codex {
                decisionObject["message"] = "Denied from Denny for Agents"
            }
        }
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": HookEventName.permissionRequest.rawValue,
                "decision": decisionObject
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stop: the agent goes on with what the user answered from the phone.
    /// Claude Code and Codex both read `decision: block` + `reason` this way.
    public static func stopContinuation(_ reply: String) -> String? {
        let text = PhoneReplies.clean(reply)
        guard !text.isEmpty else { return nil }
        let output = ["decision": "block", "reason": PhoneReplies.instruction(text)]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
