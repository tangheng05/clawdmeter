<p align="center">
  <img src="assets/icon.png" width="128" alt="Clawdmeter app icon">
</p>

<h1 align="center">clawdmeter</h1>

<p align="center">
  A tiny Clawd in your Mac menu bar that shows what Claude Code is doing,<br>
  and how much of your usage limits you have left.
</p>

<p align="center">
  <a href="https://github.com/tangheng05/clawdmeter/releases/latest"><img src="https://img.shields.io/github/v/release/tangheng05/clawdmeter?color=d97757&label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-555" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/license-MIT-555" alt="MIT license">
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/hero-dark.png">
  <img src="assets/hero-light.png" alt="Clawdmeter in the menu bar, with its popover open showing usage limits and three Claude Code sessions" width="760">
</picture>

## Install

You need **macOS 26 (Tahoe) or later** and [Claude Code](https://claude.com/claude-code).

Open **Terminal**, paste this line, and press Return:

```sh
curl -fsSL https://raw.githubusercontent.com/tangheng05/clawdmeter/main/install.sh | sh
```

That's it. An orange Clawd appears in your menu bar, and a short welcome screen helps you turn on notifications and opening at login. Send a message in Claude Code and it starts tracking.

<details>
<summary>Using Homebrew?</summary>

```sh
brew install --cask tangheng05/tap/clawdmeter
```

</details>

<details>
<summary>Prefer to download it yourself?</summary>

1. Download **Clawdmeter.zip** from the [latest release](https://github.com/tangheng05/clawdmeter/releases/latest).
2. Open the zip and drag **Clawdmeter** into your **Applications** folder.
3. Open it. macOS will say it can't check the app for malicious software, because this free app isn't registered with Apple. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down, click **Open Anyway**, then confirm with your password.

</details>

## Meet Clawd

Clawd lives in your menu bar and acts out what Claude is doing, so you can tell at a glance without switching windows.

<table>
  <tr>
    <td align="center" width="33%"><img src="assets/moods/working.png" width="88" alt="Clawd scuttling"><br><b>Working</b><br>Scuttles while Claude works</td>
    <td align="center" width="33%"><img src="assets/moods/waiting.png" width="88" alt="Clawd waving its claws"><br><b>Needs you</b><br>Waves its claws, with a yellow dot</td>
    <td align="center" width="33%"><img src="assets/moods/done.png" width="88" alt="Clawd hopping"><br><b>Done</b><br>Hops when a longer task finishes</td>
  </tr>
  <tr>
    <td align="center"><img src="assets/moods/idle.png" width="88" alt="Clawd dozing"><br><b>Idle</b><br>Dozes off with a little z</td>
    <td align="center"><img src="assets/moods/sweating.png" width="88" alt="Clawd sweating"><br><b>Close to a limit</b><br>Breaks a sweat at 90%</td>
    <td align="center"><img src="assets/moods/asleep.png" width="88" alt="Faded Clawd"><br><b>No sessions</b><br>Fades out and waits</td>
  </tr>
</table>

Next to Clawd, `wk 86%` shows whichever limit is closest to running out (`5h` or `wk`). It turns amber at 70% and red at 90%. A number like `2` shows how many sessions are open, when there's more than one.

Clawd costs your Mac almost nothing. The animations run in macOS's own animation engine and the app only wakes up when something changes, so it uses close to 0% CPU even while Clawd moves.

## The popover

Click Clawd, or press **⌃⌥⌘C** from any app, to see:

- **Both limits** with their reset times, and a forecast for each: on track, or when you'll run out at your current pace.
- **Last 7 days:** how much of your weekly limit you used each day. It appears once you have a couple of days of history.
- **Every session** with its folder, git branch and what it's doing. **Click a session to jump to it.** Terminal and iTerm2 open the exact tab (macOS asks once for permission), tmux switches to the right pane, VS Code, Cursor, Windsurf and Zed open the project window, and other apps come to the front.

Click the gear (or press ⌘,) for **Settings**: what shows in the menu bar, notifications, updates, and the **keyboard shortcut**. To change the shortcut, click it and press the keys you want. Clawdmeter turns on **Launch at login** for you, so it's there after a restart; you can switch that off in Settings too.

## Notifications

Clawdmeter can tell you when:

- a task that took 30 seconds or more finishes,
- a session needs your answer,
- a limit reaches 80% or 95%, or resets after heavy use.

It stays quiet when the app running that session is already in front. Click a notification to jump to the session. Choose which ones you want, and whether they play a sound, in Settings.

## What it changes on your Mac

The first time it opens, Clawdmeter connects itself to Claude Code by adding a status line and a few hooks to `~/.claude/settings.json`. A backup of that file is saved next to it first.

You'll notice a short line at the bottom of Claude Code showing your model, folder and usage. If you already had your own status line, it keeps working as before.

Clawdmeter uses no Claude tokens, and everything it tracks stays on your Mac. The only thing it does online is check GitHub once a day for a new version, which you can turn off in Settings.

## Troubleshooting

**Don't see Clawd?** Press ⌃⌥⌘C to open it. On MacBooks with a notch, menu bar items can hide behind it; quit a few other menu bar apps or check **System Settings → Menu Bar**.

**No notifications.** Open **System Settings → Notifications → Clawdmeter** and allow them.

**Clicking a session doesn't open the right tab.** Allow Clawdmeter under **System Settings → Privacy & Security → Automation**.

**No sessions show up.** Send a message in Claude Code, or start a new session. Sessions that were open before you installed appear once they do something.

**"Usage limits show up after your next Claude Code message."** Send a message and they appear. Limits are only available when you sign in to Claude Code with a Claude subscription, not with an API key, Bedrock or Vertex.

**The usage numbers look faded.** They haven't been updated for over 10 minutes. They refresh the next time Claude replies.

**"Clawdmeter can't be opened."** Go to **System Settings → Privacy & Security** and click **Open Anyway**.

## Update

Clawdmeter checks for new versions once a day. When one is out, click **Update** in the popover and it installs and restarts itself. You can also click **Check now** in Settings.

Installed with Homebrew? Run `brew upgrade clawdmeter` instead.

## Uninstall

1. Click Clawd, then the gear, then **Disconnect** under Claude Code.
2. Click **Quit**, and drag **Clawdmeter** from Applications to the Trash.

With Homebrew, `brew uninstall --zap clawdmeter` does both steps.

Already deleted the app? Run `~/.claude/clawdmeter/bin/clawdmeter uninstall` in Terminal to remove its hooks and status line from Claude Code.

## Build from source

```sh
git clone https://github.com/tangheng05/clawdmeter.git
cd clawdmeter
make install   # build and install into Applications
swift test     # run the tests
```

## License

MIT
