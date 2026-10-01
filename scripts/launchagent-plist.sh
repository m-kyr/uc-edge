#!/bin/bash
# Print the LaunchAgent plist for a given home directory (used by install-local.sh and
# deploy-remote.sh). Usage: launchagent-plist.sh HOME_DIR
set -euo pipefail
H=${1:?usage: launchagent-plist.sh HOME_DIR}
cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>local.uc-edge</string>
	<key>ProgramArguments</key>
	<array>
		<string>$H/Applications/UCEdge.app/Contents/MacOS/UCEdge</string>
		<string>run</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
	<key>StandardOutPath</key>
	<string>$H/Library/Logs/UCEdge/launchd.log</string>
	<key>StandardErrorPath</key>
	<string>$H/Library/Logs/UCEdge/launchd.log</string>
</dict>
</plist>
EOF
