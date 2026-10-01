#!/bin/bash
# Print the LaunchAgent plist for the menu bar app for a given home directory.
# Starts at login; restarted only if it crashes, so "Quit UCEdge" lasts until the next login.
# Usage: menu-agent-plist.sh HOME_DIR
set -euo pipefail
H=${1:?usage: menu-agent-plist.sh HOME_DIR}
cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>local.uc-edge.menu</string>
	<key>ProgramArguments</key>
	<array>
		<string>$H/Applications/UCEdge Menu.app/Contents/MacOS/UCEdgeMenu</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
	<key>StandardOutPath</key>
	<string>$H/Library/Logs/UCEdge/menu.log</string>
	<key>StandardErrorPath</key>
	<string>$H/Library/Logs/UCEdge/menu.log</string>
</dict>
</plist>
PLIST
