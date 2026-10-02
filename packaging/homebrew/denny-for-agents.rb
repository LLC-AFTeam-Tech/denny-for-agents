# Cask for a personal tap (github.com/LLC-AFTeam-Tech/homebrew-tap, Casks/denny-for-agents.rb).
# After each release: set version, and sha256 from `shasum -a 256 DennyForAgents.zip`.
cask "denny-for-agents" do
  version "0.2.0"
  sha256 "71e1f3a83b1734a9b4893a3c0286c92ed7b4872c773ae12c46077cd7b4ac4628"

  url "https://github.com/LLC-AFTeam-Tech/denny-for-agents/releases/download/v#{version}/DennyForAgents.zip"
  name "Denny for Agents"
  desc "Notch companion that watches Claude Code and Codex"
  homepage "https://github.com/LLC-AFTeam-Tech/denny-for-agents"

  depends_on macos: ">= :ventura"

  app "Denny for Agents.app"

  uninstall quit: "tech.afteam.denny-for-agents"

  zap trash: [
    "~/.denny-for-agents",
    "~/Library/Preferences/tech.afteam.denny-for-agents.plist",
  ]

  caveats <<~EOS
    Denny for Agents is not notarized yet. If macOS refuses to open it, run:
      xattr -dr com.apple.quarantine "/Applications/Denny for Agents.app"
    Hooks it added can be removed from its menu bar icon before uninstalling.
  EOS
end
