"""Require the microphone entitlement in the main app's actual code signature."""
import plistlib
import subprocess
import sys

app = sys.argv[1]
signed = subprocess.check_output(["codesign", "--display", "--entitlements", "-", "--xml", app])
entitlements = plistlib.loads(signed) if signed else {}
if entitlements.get("com.apple.security.device.audio-input") is not True:
    sys.exit(f"{app}: signed microphone entitlement com.apple.security.device.audio-input is missing or false")
