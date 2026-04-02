#!/bin/bash

# 1. Ensure we find the right binary
CLAUDE_BIN=$(which openclaude)
if [ -z "$CLAUDE_BIN" ]; then
    echo "❌ Error: 'openclaude' not found."
    exit 1
fi

# 2. Configuration
LOG_FILE="progress.md"
TARGET_DIR="src"
ZIG_CMD="zig build -Drelease=true --color on --error-style minimal -freference-trace=0"

# 3. Initialize Progress if needed
if [ ! -f "$LOG_FILE" ]; then
    echo "## Pending Files" > "$LOG_FILE"
    find "$TARGET_DIR" -type f \( -name "*.zig" -o -name "*.c" \) >> "$LOG_FILE"
    echo -e "\n## Checked Files" >> "$LOG_FILE"
fi

# 4. Process loop
while true; do
    # Get the first file from the pending list
    FILE=$(sed -n '/## Pending Files/,/## Checked Files/p' "$LOG_FILE" | grep -v "##" | sed '/^[[:space:]]*$/d' | head -n 1)

    if [ -z "$FILE" ]; then
        echo "🎉 All files finished!"
        break
    fi

    echo "🚀 Starting: $FILE"

    # STEP 1: ELABORATE
    #  skips "are you sure?" prompts
    # --prompt tells it to execute the string and exit
    $CLAUDE_BIN  --prompt "Analyze $FILE. Create a file 'improvements.md' with Zig-idiomatic improvements for safety and performance. Do not edit $FILE yet."
    
    if [ $? -ne 0 ]; then echo "❌ Step 1 failed for $FILE"; exit 1; fi

    # STEP 2: APPLY & DEBUG LOOP
    # We give it the full zig command so it can self-correct
    $CLAUDE_BIN  --prompt "Read improvements.md. Apply all changes to $FILE. Then run '$ZIG_CMD'. If errors occur, read them and fix $FILE. Repeat until success. Finally delete improvements.md."

    if [ $? -ne 0 ]; then echo "❌ Step 2 failed for $FILE"; exit 1; fi

    # STEP 3: UPDATE PROGRESS (macOS sed)
    ESCAPED_FILE=$(echo "$FILE" | sed 's/\//\\\//g')
    sed -i "" "/^$ESCAPED_FILE$/d" "$LOG_FILE"
    echo "$FILE" >> "$LOG_FILE"
    
    echo "✅ Finished $FILE. Context cleared for next file."
done
