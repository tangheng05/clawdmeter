cask "clawdmeter" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/tangheng05/clawdmeter/releases/download/v#{version}/Clawdmeter.zip"
  name "Clawdmeter"
  desc "Menu bar status and usage limits for Claude Code"
  homepage "https://github.com/tangheng05/clawdmeter"

  depends_on macos: :tahoe

  app "Clawdmeter.app"

  # The app isn't notarized; this skips the "Open Anyway" step.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "/Applications/Clawdmeter.app"],
        must_succeed:   false,
        writable_paths: ["Clawdmeter.app"],
        writable_base:  :appdir
  end

  uninstall quit: "io.github.tangheng05.clawdmeter"

  # Removes Clawdmeter's hooks and status line from Claude Code before its files go.
  zap script: {
        executable:   "#{Dir.home}/.claude/clawdmeter/bin/clawdmeter",
        args:         ["uninstall"],
        must_succeed: false,
      },
      trash:  "~/Library/Preferences/io.github.tangheng05.clawdmeter.plist"
end
