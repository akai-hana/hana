#!/bin/bash
# Bar Transparency Deep Diagnostic
# Run this while your bar is running

echo "=== Bar Transparency Deep Diagnostic ==="
echo

# Find the bar window
echo "1. Finding bar window..."
BAR_WINDOW=$(xdotool search --class "hana" 2>/dev/null | head -1)

if [ -z "$BAR_WINDOW" ]; then
    echo "   Trying alternative methods..."
    BAR_WINDOW=$(xdotool search --name "hana" 2>/dev/null | head -1)
fi

if [ -z "$BAR_WINDOW" ]; then
    echo "   ✗ Could not find bar window!"
    echo "   Make sure your bar is running."
    exit 1
fi

echo "   ✓ Found bar window: 0x$(printf '%x' $BAR_WINDOW)"
echo

# Check window depth
echo "2. Checking window depth..."
DEPTH=$(xwininfo -id $BAR_WINDOW | grep "Depth:" | awk '{print $2}')
echo "   Window depth: $DEPTH"

if [ "$DEPTH" = "32" ]; then
    echo "   ✓ Window has 32-bit depth (ARGB capable)"
elif [ "$DEPTH" = "24" ]; then
    echo "   ✗ Window has 24-bit depth (NO ALPHA CHANNEL)"
    echo "   → This is the problem! Window was created with wrong depth."
else
    echo "   ? Window has unusual depth: $DEPTH"
fi
echo

# Check visual class
echo "3. Checking visual class..."
xwininfo -id $BAR_WINDOW | grep -i "visual"
echo

# Check window properties
echo "4. Checking window properties..."
xprop -id $BAR_WINDOW | grep -E "_NET_WM|OPACITY|ALPHA" || echo "   No transparency-related properties found"
echo

# Check if window has _NET_WM_WINDOW_OPACITY
echo "5. Checking _NET_WM_WINDOW_OPACITY property..."
OPACITY=$(xprop -id $BAR_WINDOW _NET_WM_WINDOW_OPACITY 2>/dev/null | grep -v "not found")
if [ -n "$OPACITY" ]; then
    echo "   $OPACITY"
else
    echo "   ✗ _NET_WM_WINDOW_OPACITY not set"
    echo "   → This might be okay for native ARGB transparency"
fi
echo

# Check compositor
echo "6. Checking compositor configuration..."
if pgrep -x picom > /dev/null; then
    echo "   ✓ picom is running (PID: $(pgrep -x picom))"
    
    # Check if compositor can see our window
    PICOM_DEBUG=$(picom --diagnostics 2>&1 | grep -i argb)
    if [ -n "$PICOM_DEBUG" ]; then
        echo "   Picom ARGB info: $PICOM_DEBUG"
    fi
else
    echo "   ✗ picom is not running!"
fi
echo

# Check actual window attributes
echo "7. Checking X11 window attributes..."
xwininfo -id $BAR_WINDOW -all | grep -E "Depth|Visual|Class|Map State|Override"
echo

# Test with xcompmgr if available
echo "8. Testing transparency detection..."
if command -v transset-df &> /dev/null; then
    echo "   Testing with transset-df..."
    CURRENT=$(transset-df -i $BAR_WINDOW 2>&1)
    echo "   Current opacity: $CURRENT"
elif command -v transset &> /dev/null; then
    echo "   Testing with transset..."
    CURRENT=$(transset -i $BAR_WINDOW 2>&1)
    echo "   Current opacity: $CURRENT"
else
    echo "   ⚠ transset not available (install: sudo apt install xcompmgr)"
fi
echo

# Check the actual visual ID
echo "9. Checking if ARGB visual was actually used..."
VISUAL_ID=$(xwininfo -id $BAR_WINDOW | grep "Visual ID" | awk '{print $3}')
echo "   Visual ID: $VISUAL_ID"

# Get all 32-bit visuals on the screen
echo "   Available 32-bit ARGB visuals:"
xdpyinfo | grep -A2 "depth.*32" | grep "visual id" || echo "   ✗ No 32-bit visuals available!"
echo

# Try to get the window class
echo "10. Window identification..."
xprop -id $BAR_WINDOW WM_CLASS WM_NAME
echo

# Summary
echo "=== SUMMARY ==="
echo

if [ "$DEPTH" != "32" ]; then
    echo "❌ MAIN ISSUE: Window depth is $DEPTH, not 32!"
    echo
    echo "This means the window was NOT created with ARGB visual."
    echo "Check your bar's debug output when it starts. You should see:"
    echo "  'Found 32-bit ARGB visual (id=0x...)'"
    echo "  'Created 32-bit ARGB window for transparency'"
    echo
    echo "If you don't see this, the XCB_BACK_PIXMAP_NONE constant might be wrong."
    echo
    echo "IMMEDIATE FIX TO TRY:"
    echo "Add this to your bar.zig before the window creation code:"
    echo "  const XCB_BACK_PIXMAP_NONE: u32 = 0;"
    echo
elif ! pgrep -x picom > /dev/null; then
    echo "❌ MAIN ISSUE: Compositor not running!"
    echo "Start picom: picom &"
    echo
else
    echo "Window appears to be configured correctly (32-bit depth, compositor running)."
    echo
    echo "Possible issues to check:"
    echo "1. Check bar startup logs for transparency messages"
    echo "2. Try setting transparency in picom.conf:"
    echo "   opacity-rule = ['90:class_g = \"hana\"'];"
    echo "3. Check if compositor is actually compositing:"
    echo "   killall picom; picom --log-level debug 2>&1 | grep -i alpha"
    echo "4. Verify config.toml transparency value is < 1.0"
fi

echo
echo "=== BAR DEBUG OUTPUT ==="
echo "Check your bar's startup output for these messages:"
echo "- 'Bar transparency config: XX.XX% (want=true, alpha16=0x...)'"
echo "- 'Found 32-bit ARGB visual (id=0x...)'"
echo "- 'Created 32-bit ARGB window for transparency (depth=32, ...)'"
echo
echo "If you DON'T see these messages, the ARGB window isn't being created."
