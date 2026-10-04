# clawdmeter

A tiny menu bar app for Claude Code on Mac. See at a glance whether Claude is working or waiting for you, and how much of your usage limits you have left.

<img src="assets/menubar.png" height="30"> <br>
<img src="assets/popover.png" width="320">

## Install

You need **macOS 26 (Tahoe) or later** and [Claude Code](https://claude.com/claude-code).

Open **Terminal**, paste this line, and press Return:

```sh
curl -fsSL https://raw.githubusercontent.com/tangheng05/clawdmeter/main/install.sh | sh
```

That's it. An orange Clawd appears in your menu bar. Send a message in Claude Code and it starts tracking.

<details>
<summary>Prefer to download it yourself?</summary>

1. Download **Clawdmeter.zip** from the [latest release](https://github.com/tangheng05/clawdmeter/releases/latest).
2. Open the zip and drag **Clawdmeter** into your **Applications** folder.
3. Open it. macOS will say it can't check the app for malicious software, because this free app isn't registered with Apple. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

</details>

## What the menu bar shows

| You see | It means |
| --- | --- |
| Clawd walking | Claude is working |
| Yellow dot | A session needs you, like a permission question |
| Clawd standing still | Everything is idle |
| Faded Clawd | No Claude Code sessions are open |
| `wk 86%` | Usage of whichever limit is closest to running out (`5h` or `wk`). Turns amber at 70% and red at 90% |
| `2` | Number of sessions, when more than one is open |

Click Clawd to see both limits with their reset times, and every session with its folder, git branch and what it's doing.

Click the gear to choose what shows in the menu bar or to turn on **Launch at login**, so it's always there when you start your Mac.

## What it changes on your Mac

The first time it opens, Clawdmeter connects itself to Claude Code by adding a status line and a few hooks to `~/.claude/settings.json`. A backup of that file is saved next to it first.

You'll notice a short line at the bottom of Claude Code showing your model, folder and usage. If you already had your own status line, it keeps working as before.

Clawdmeter uses no Claude tokens and never goes online. Everything stays on your Mac.

## Troubleshooting

**No sessions show up.** Send a message in Claude Code, or start a new session. Sessions that were open before you installed appear once they do something.

**"Usage limits show up after your next Claude Code message."** Send a message and they appear. Limits are only available when you sign in to Claude Code with a Claude subscription, not with an API key, Bedrock or Vertex.

**The usage numbers look faded.** They haven't been updated for over 10 minutes. They refresh the next time Claude replies.

**"Clawdmeter can't be opened."** Go to **System Settings → Privacy & Security** and click **Open Anyway**.

## Update

Run the install command again.

## Uninstall

1. Click Clawd, then the gear, then **Remove Claude Code integration**.
2. Click **Quit**, and drag **Clawdmeter** from Applications to the Trash.

## Build from source

```sh
git clone https://github.com/tangheng05/clawdmeter.git
cd clawdmeter
make install   # build and install into Applications
swift test     # run the tests
```

## License

MIT
