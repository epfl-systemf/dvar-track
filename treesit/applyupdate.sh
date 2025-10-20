#!/usr/bin/bash
echo "restore..."
find . -iname "*.bak" | sed 's/\.bak//' | xargs -I@@ mv @@.bak @@
echo "backup..."
find . -iname "*.updated" | sed 's/\.updated//' | xargs -I@@ mv @@ @@.bak
echo "apply update..." 
find . -iname "*.updated" | sed 's/\.updated//' | xargs -I@@ mv @@.updated @@
echo "done"
