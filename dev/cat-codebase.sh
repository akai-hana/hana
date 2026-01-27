#!/bin/sh
echo "ls src/bar"
ls

echo "tree src/bar"
tree src/bar

find ./src/bar -type f -name "*.zig" | while read -r file; do
    echo "=== Printing file "$file" ==="
    cat "$file"
    echo ""
done

zig version
