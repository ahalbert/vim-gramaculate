Output demo.gif

Set FontSize 16
Set Width 1200
Set Height 450
Set Theme "Dracula"
Set Shell "bash"

# Open the demo file
Type "vim demo.md"
Enter
Sleep 1s

# Run Gramaculate
Type ":Gramaculate"
Enter
Sleep 8s

# Apply first two fixes
Enter
Sleep 500ms
Enter
Sleep 500ms

# Close the fix window
Type "q"
Sleep 1s

# Quit vim
Type ":q!"
Enter
