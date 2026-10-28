#!/bin/zsh
# Copy to .release-config.sh and fill in values for this Mac.
# .release-config.sh is gitignored; notarization credentials stay in Keychain.
export CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export INSTALLER_IDENTITY='Developer ID Installer: Your Name (TEAMID)'
export NOTARY_PROFILE='your-notary-keychain-profile'
export IOS_DEVICE_ID='YOUR_IPHONE_DEVICE_ID'
