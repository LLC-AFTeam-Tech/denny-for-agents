import AgentCore
import Foundation

// Called by Claude Code / Codex as `denny-hook <claude|codex>` with the hook
// payload on stdin. Rule number one: never get in the agent's way. If Denny
// isn't running, the payload is odd, or nobody answers in time, exit 0 with
// no output and the agent carries on exactly as without the hook.

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
guard arguments.count >= 2, let agent = AgentKind(rawValue: arguments[1]) else { exit(0) }

let payload = FileHandle.standardInput.readDataToEndOfFile()
guard var event = try? HookEvent.parse(payload, agent: agent) else { exit(0) }
// The safety net works even when Denny isn't running: the snapshot is taken
// before the command runs, whatever happens to the notch.
if event.name == .preToolUse {
    event.snapshot = SafetyNet.take(command: SafetyNet.command(fromPayload: payload), cwd: event.cwd, agent: agent.rawValue)
}
guard let socket = UnixSocket.connect(path: BridgePaths.socket().path) else { exit(0) }

let wantsDecision = event.name == .permissionRequest
let request = BridgeRequest(id: UUID().uuidString, event: event, wantsDecision: wantsDecision)
guard let line = try? BridgeCodec.encodeLine(request), socket.write(line) else { exit(0) }
guard wantsDecision else { exit(0) }

socket.setReceiveTimeout(seconds: HookInstaller.approvalWaitSeconds)
guard let reply = socket.readLine(),
      let response = try? BridgeCodec.decode(BridgeResponse.self, line: reply),
      response.id == request.id,
      let output = HookOutput.permissionResponse(response.decision, agent: agent) else { exit(0) }

FileHandle.standardOutput.write(Data((output + "\n").utf8))
exit(0)
