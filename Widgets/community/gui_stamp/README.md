# GUI Stamp
A widget for Beyond All Reason that allows you to make a drawing and save it for future use...a 

## How it works
 Draw on the map, save the strokes, stamp them as real backtick map marks.

   Ctrl+Alt+D   draw mode (LMB drag)
   Ctrl+Alt+Z   clear unsaved strokes
   Ctrl+Alt+T   save strokes as a stamp
   Ctrl+Alt+B   paste mode (LMB stamps real map marks)
   Ctrl+Alt+[ ] previous / next stamp
   [ ]          rotate counter-clockwise / clockwise (paste mode only,
                uses the game's own build-facing keys)
   Ctrl+Alt+Y   delete selected saved stamp
   Ctrl+Alt+X   cancel all stamping in progress
   RMB / Esc    cancel draw/paste mode

## Safety
Only draws, does not change any settings.

## Configuration
 
 Install via the plugins tab in the lobby. 

 
there is also a python converter that allows you to import svg files into the library:
python svg_to_stamp.py art.svg --merge "<<Beyond-All-Reason dir>>\data\LuaUI\Config\gui_stamps.json" --name my-logo --width 600

## Manual installation

Install: <BAR data>/LuaUI/Widgets/gui_stamp.lua
 Then: /luaui reload
 Saved to LuaUI/Config/gui_stamps.json
