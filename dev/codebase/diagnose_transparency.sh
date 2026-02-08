#!/bin/bash
# Bar Transparency Diagnostic Script
# Run this while your WM is running

echo "=== Bar Transparency Diagnostics ==="
echo ""

# 1. Check if picom is running
echo "1. Checking compositor..."
if pgrep -x picom > /dev/null; then
    echo "   ✓ picom is running"
else
    echo "   ✗ picom is NOT running - transparency requires a compositor!"
    echo "   Start picom with: picom &"
fi
echo ""

# 2. Find the bar window
echo "2. Finding bar window..."
BAR_WINDOW=$(xdotool search --name "hana" 2>/dev/null | head -1)
if [ -z "$BAR_WINDOW" ]; then
    echo "   ✗ Could not find bar window"
    echo "   Make sure your WM is running"
    exit 1
else
    echo "   ✓ Found bar window: $BAR_WINDOW"
fi
echo ""

# 3. Check window depth (32-bit = supports transparency)
echo "3. Checking window depth..."
DEPTH=$(xwininfo -id "$BAR_WINDOW" 2>/dev/null | grep "Depth:" | awk '{print $2}')
if [ "$DEPTH" = "32" ]; then
    echo "   ✓ Window depth is 32-bit (ARGB - supports transparency)"
elif [ "$DEPTH" = "24" ]; then
    echo "   ✗ Window depth is 24-bit (RGB only - NO transparency support)"
    echo "   This means ARGB visual was not found or not used!"
else
    echo "   ? Window depth is $DEPTH (unexpected)"
fi
echo ""

# 4. Check window properties
echo "4. Checking window properties..."
xprop -id "$BAR_WINDOW" 2>/dev/null | grep -E "(_NET_WM_WINDOW_TYPE|_NET_WM_WINDOW_OPACITY)" | while read line; do
    echo "   $line"
done
echo ""

# 5. Check WM debug output for transparency messages
echo "5. Checking for transparency in WM output..."
echo "   If you started your WM in a terminal, look for messages like:"
echo "   'Bar transparency: enabled at XX.XX%'"
echo "   or"
echo "   '32-bit ARGB visual not available'"
echo ""

# 6. Visual test
echo "6. Visual test - Click on the bar when cursor appears..."
echo "   (This will show detailed window info)"
sleep 1
xwininfo | grep -E "(Window id:|Depth:|Visual:|Colormap:|Bit gravity:|Border width:|Map State:)"
echo ""

echo "=== Summary ==="
if [ "$DEPTH" = "32" ]; then
    echo "✓ Bar window is using ARGB visual (transparency capable)"
    echo ""
    echo "If bar still appears opaque, the issue is likely:"
    echo "  1. Picom not compositing ARGB windows (check picom config)"
    echo "  2. clearTransparent() not being called (check WM debug output)"
    echo "  3. Alpha values not being set correctly in Cairo"
else
    echo "✗ Bar window is NOT using ARGB visual"
    echo ""
    echo "This is the problem! Possible causes:"
    echo "  1. X server doesn't support 32-bit visuals (run: xdpyinfo | grep depths)"
    echo "  2. ARGB visual not found by findVisualByDepth()"
    echo "  3. Code is falling back to default visual"
fi
