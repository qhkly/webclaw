#!/bin/bash
# Patch noVNC HTML file with meta tag and script references

VNC_HTML="/opt/noVNC/vnc.html"

if [ -f "$VNC_HTML" ]; then
    # Add meta charset tag
    sed -i 's|<head>|<head><meta charset="UTF-8">|' "$VNC_HTML"

    # Add audio-bar.js reference (before </head>)
    sed -i 's|</head>|<script src="audio-bar.js"></script>|' "$VNC_HTML"

    # Add touch-handler.js reference (after audio-bar.js)
    # Version query busts the browser cache when touch-handler.js changes.
    sed -i 's|<script src="audio-bar.js"></script>|<script src="audio-bar.js"></script><script src="touch-handler.js?v=20260702"></script>|' "$VNC_HTML"

    # Add key-remap.js reference (after touch-handler.js)
    sed -i 's|<script src="touch-handler.js?v=20260702"></script>|<script src="touch-handler.js?v=20260702"></script><script src="key-remap.js"></script>|' "$VNC_HTML"

    echo "noVNC HTML patched successfully"
else
    echo "noVNC HTML not found, skipping (lite mode)"
fi
