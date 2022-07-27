![alt text](https://github.com/knector01/wm.lua/blob/master/wm-screenshot.png?raw=true)

# wm.lua

This program is a rewrite of a WM I wrote back in 2014. For this version I switched to using the built-in CC window API for rendering, and I tried my best to keep the code somewhat readable. I also added some features:

* window maximization
* multishell API implementation
* new application launcher

## Installation

To install the WM on a ComputerCraft computer, run the following command:

`pastebin get V9JvkCc1 wm.lua`

Then run `wm.lua` to start the window manager. You can rename the file to `startup.lua` to make it run on startup.

## Usage

Right-click the desktop to open the application launcher. Note that CC applications like `edit` or `paint` require additional command-line arguments and should be launched through the "Run..." menu or a shell window.

Windows work as you'd expect: Drag the title bar of a window to move it, and click the buttons to minimize, maximize, or close the window. Drag the lower-right corner a window to resize it. Press Ctrl-Tab to switch windows. This can also restore minimized windows.

## Notes for application development

* Events not emitted by the mouse or keyboard, such as timers or rednet messages, are redirected by the WM to all running programs.
* If your application uses timers, make sure to check IDs of received timer events to avoid conflicts with other running applications' timers.
* If your application is dependent on the window size, then you can listen for term_resize events and adjust the UI accordingly.
* Additionally, the WM provides a modified multishell API that allows applications to open additional windows as needed. The API should work seamlessly with existing multishell applications. shell.openTab and related library functions also work.

The following events are emitted by the window manager:
* `wm_focus <focused>`: emitted when a window gains or loses focus
* `wm_log <message>`: internal debug messages from the WM
* `term_resize`: emitted when a window is resized
