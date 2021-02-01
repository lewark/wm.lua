-- wm.lua: graphical window manager for ComputerCraft

--[[
	Copyright (c) 2021 knector01

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
--]]

--[[
	**About the WM**

	Yeah, it's another one of these. I did try to make it pretty straightforward
		to use, and it *should* work well with existing applications.
	This program is a rewrite of a WM I wrote back in 2014. For this version I
		switched to using the built-in CC window API for rendering, and I tried
		my best to keep the code somewhat readable. I also added some features
		like window maximization, a multishell API implementation, and a new
		application launcher.

	Usage:
		Right-click the desktop to open the run menu.
		Windows work as you'd expect: Drag the title bar of a window to move it,
			and click the buttons to minimize, maximize, or close the window. Wowee.
		Drag the lower-right corner a window to resize it.
		Press Ctrl-Tab to switch windows. This can also restore minimized windows.

	Notes for application development:
		Events not emitted by the mouse or keyboard, such as timers or rednet
			messages, are redirected by the WM to all running programs.
		If your application uses timers, make sure to check IDs of received timer
			events to avoid conflicts with other running applications' timers.
		If your application is dependent on the window size, then you can listen
			for term_resize events and adjust the UI accordingly.
		Additionally, the WM provides a modified multishell API that allows
			applications to open additional windows as needed. The API should work
			seamlessly with existing multishell applications. shell.openTab
			and related library functions also work.

		The following events are emitted by the window manager:
			wm_focus <focused>
				emitted when a window gains or loses focus
			wm_log <message>
				internal debug messages from the WM
			term_resize
				emitted when a window is resized
--]]

-- Events which should be sent to the focused window
local EVENTS_KEYBD = {"char","key","key_up","paste","terminate"}
-- Events which have X/Y coordinates
local EVENTS_MOUSE = {"mouse_click","mouse_up","mouse_scroll","mouse_drag"}
-- Events which have X/Y coordinates and should only be sent to the window they are over
local EVENTS_TOP = {"mouse_click","mouse_scroll"}
-- Other events (rednet, timers, etc) are sent to all windows

-- Minimum window size
local MIN_WIDTH = 4
local MIN_HEIGHT = 3

-- Default window properties
local DEFAULT_WIDTH = 20
local DEFAULT_HEIGHT = 10
local DEFAULT_X = 4
local DEFAULT_Y = 3

-- Enable to draw drop shadow under windows
local SHADOW_ENABLE = false

local DRAG_MOVE = 0
local DRAG_RESIZE = 1

local WM_COLORS = {
	bg = colors.lightBlue,
	shadow = colors.gray,
	title_unfocused = colors.gray,
	title_focused = colors.blue,
	title_text = colors.white,
	title_close = colors.red,
	resize_bg = colors.white,
	resize_fg = colors.lightGray,
	menu = colors.white,
	menu_text = colors.black,
	menu_sel = colors.blue,
	menu_sel_text = colors.white,
	run = colors.white,
	run_text = colors.black
}

local processes = {}
local processes_visible = {}
local event_queue = {}
local process_focus = 0
local process_current = 0

local term_original = term.current()

local drag_state

local draw_background = false

local control_held = false

local multishell_ext = {}

-- BUG: textutils.pagedPrint seems broken under wm.lua, investigate
-- for example, "set" command does not seem to scroll correctly

local function queue_event(id, evt)
	table.insert(event_queue, 1, {id, evt})
end

local function str_pad(str, length)
	if #str > length then
		str = string.sub(str,1,length)
	elseif #str < length then
		str = str .. string.rep(" ",length-#str)
	end
	return str
end

local function contains(arr, elem)
	for _, v in pairs(arr) do
		if v == elem then
			return true
		end
	end
	return false
end

local function index(arr, elem)
	for k, v in pairs(arr) do
		if v == elem then
			return k
		end
	end
	return nil
end

local function table_copy(tbl)
	local copy = {}
	for k,v in pairs(tbl) do
		copy[k] = v
	end
	return copy
end

local function process_subwindow_properties(id)
	local process = processes[id]
	if process.border then
		return process.x, process.y+1, process.w, process.h-1
	end
	return process.x, process.y, process.w, process.h
end

-- schedules a redraw of the window manager
-- (no arguments): redraw everything
-- (id): redraw border of specified window, as well as border
--       and contents of all windows above it
-- (id, force): same as id, except if force is true then also
--       redraw the contents of the specified window
local function wm_dirty(id,force)
	if id then
		local process = processes[id]
		local layer = index(processes_visible,id)
		if force then
			process.dirty = 2
		elseif process.dirty == 0 then
			process.dirty = 1
		end
		if layer then
			for i=layer+1,#processes_visible do
				processes[processes_visible[i]].dirty = 2
			end
		end
	else
		draw_background = true
		for i=1,#processes_visible do
			processes[processes_visible[i]].dirty = 2
		end
	end
end

local function process_end(id)
	table.remove(processes, id)
	if process_focus == id then
		process_focus = 0
	elseif process_focus > id then
		process_focus = process_focus - 1
	end
	
	local i = index(processes_visible, id)
	if i then
		table.remove(processes_visible, i)
	end
	
	for i=1,#processes_visible do
		if processes_visible[i] > id then
			processes_visible[i] = processes_visible[i] - 1
		end
	end
	
	for i=#event_queue,1,-1 do
		local evt = event_queue[i]
		if evt[1] > id then
			evt[1] = evt[1] - 1
		elseif evt[1] == id then
			table.remove(event_queue,i)
		end
	end
	
	wm_dirty()
end

local function wm_log(text) end

local function prompt_keypress()
	term.write("Press any key")
	os.pullEvent("key")
end

local function process_resume(id, args, initial)
	local process = processes[id]
	local current_run = process_current
	
	if not process.coroutine then return end
	if process.filter and args[1] ~= process.filter and args[1] ~= "terminate" then return end
	
	process_current = id
	term.redirect(process.window)
	local status, ret = coroutine.resume(process.coroutine, unpack(args))
	--if status then
	process.filter = ret
	--end
	--wm_log("process_resume "..tostring(id).." "..tostring(status).." "..tostring(ret))
	
	if coroutine.status(process.coroutine) == "dead" then --not status then --
		if initial then
			-- prompt for keypress if program immediately exits
			-- BUG: shows title of "shell" if this occurs
			process.coroutine = coroutine.create(prompt_keypress)
			queue_event(id,{})
		else
			process_end(id)
		end
	else
		-- TODO: Only set dirty flag when application is drawn to
		wm_dirty(id)
	end
	
	if current_run > 0 then
		process_current = current_run
		processes[current_run].window.restoreCursor()
		term.redirect(processes[current_run].window)
	else
		process_current = 0
		term.redirect(term_original)
	end
end

local function wm_log(text)
	local event = {"wm_log",text}
	for i=#processes,1,-1 do
		queue_event(i,event)
	end
end

-- base process constructor
-- runs an arbitrary function inside a process
local function process_create(func, title, x, y, w, h)
	local process = {}
	
	local current_run = process_current
	
	table.insert(processes, process)
	table.insert(processes_visible, #processes)
	
	process.x = x or DEFAULT_X
	process.y = y or DEFAULT_Y
	process.w = w or DEFAULT_WIDTH
	process.h = h or DEFAULT_HEIGHT
	process.visible = true
	process.border = true
	process.title = title
	process.dirty = 2
	process.filter = nil
	process.maximized = false
	process.old_pos = {}
	
	px,py,pw,ph = process_subwindow_properties(#processes)
	process.window = window.create(term_original,px,py,pw,ph,true)
	
	process_current = #processes
	
	process.coroutine = coroutine.create(func)
	
	process_current = current_run
	if process.coroutine then
		-- initial resume call must not be queued; the edit program's
		-- run button expects the process to immediately start
		process_resume(#processes,{},true)
	else
		process_end(#processes)
	end
	
	if current_run > 0 then
		process_current = current_run
		processes[current_run].window.restoreCursor()
		term.redirect(processes[current_run].window)
	end
	
	return #processes
end

-- wraps an os.run call inside a process
local function process_run(env, path, args, title, x, y, w, h)
	run_args = {}
	table.insert(run_args, env)
	table.insert(run_args, path)
	for i=1,#args do
		table.insert(run_args,args[i])
	end
	title = title or path
	
	-- add a call to read() in the function to debug errors
	return process_create(function() os.run(unpack(run_args)) end, title, x, y, w, h)
end

-- runs a shell command inside a process,
-- and lets the CraftOS shell set up the environment
-- is this hacky? maybe. it does seem to work though.
-- TODO: look into just using os.run
-- if command is nil then an interactive shell is launched
local function process_run_command(command, x, y, w, h)
	-- not sure if i'm doing this right, honestly
	-- seems to work though
	env = {shell=shell, multishell=multishell_ext}
	
	process_run(env, shell.resolveProgram("shell"), {command}, command, x, y, w, h)
end

local function process_reposition(id, x, y, w, h)
	local process = processes[id]
	local resized = false
	
	w = w or process.w
	h = h or process.h
	
	if w ~= process.w or h ~= process.h then
		resized = true
	end
	
	process.x = x
	process.y = y
	
	process.w = w
	process.h = h
	
	px,py,pw,ph = process_subwindow_properties(id)
	process.window.reposition(px,py,pw,ph)
	
	if resized then
		queue_event(id, {"term_resize"})
	end
	
	wm_dirty()
end

local function process_set_visible(id, visible)
	local process = processes[id]
	process.visible = visible
	process.window.setVisible(visible)
	if visible then
		if not contains(processes_visible, id) then
			table.insert(processes_visible, id)
		end
	else
		local i = index(processes_visible, id)
		if i then
			table.remove(processes_visible, i)
		end
	end
	wm_dirty()
end

local function process_set_title(id, title)
	local process = processes[id]
	process.title = title
	wm_dirty(id)
end

local function process_set_maximized(id, maximized)
	local process = processes[id]
	process.maximized = maximized
	if maximized then
		process.old_pos.x = process.x
		process.old_pos.y = process.y
		process.old_pos.w = process.w
		process.old_pos.h = process.h
		w,h = term.getSize()
		process_reposition(id,1,1,w,h)
	else
		process_reposition(id,
			process.old_pos.x,process.old_pos.y,
			process.old_pos.w,process.old_pos.h)
	end
end

local function process_set_focus(id, top)
	if process_focus > 0 and process_focus ~= id then
		local old_focus = process_focus
		process_focus = 0
		wm_dirty(old_focus)
		queue_event(old_focus,{"wm_focus",0})
	end
	if top then
		-- move the window to the top
		local process = processes[id]
		
		local i = index(processes_visible, id)
		if i then
			table.remove(processes_visible, i)
		end
		table.insert(processes_visible,id)
		
		if process_focus ~= id then
			process_focus = id
			queue_event(process_focus,{"wm_focus",1})
			wm_dirty(process_focus,true)
		end
	elseif process_focus ~= id then
		process_focus = id
		if process_focus > 0 then
			queue_event(process_focus,{"wm_focus",1})
			wm_dirty(process_focus)
		end
	end
end

-- draw a window's header and its contents,
-- depending on what dirty flags are set
local function process_draw(id)
	-- TODO: Add other border styles
	-- Current implementation can cover information (e.g. CC edit line number)
	local process = processes[id]
	if process.visible and process.dirty > 0 then
		if process.dirty == 2 then
			process.window.redraw()
		end
		if SHADOW_ENABLE then
			term.setBackgroundColor(WM_COLORS.shadow)
			for i=1,process.w do
				term.setCursorPos(process.x+i,process.y+process.h)
				term.write(" ")
			end
			for i=1,process.h-1 do
				term.setCursorPos(process.x+process.w,process.y+i)
				term.write(" ")
			end
		end
		if process.border then
			local title_color = WM_COLORS.title_unfocused
			if id == process_focus then
				title_color = WM_COLORS.title_focused
			end
			
			term.setBackgroundColor(title_color)
			term.setTextColor(WM_COLORS.title_text)
			term.setCursorPos(process.x, process.y)
			term.write(str_pad(process.title,process.w-3))
			
			term.setBackgroundColor(WM_COLORS.title_text)
			term.setTextColor(title_color)
			term.write(string.char(22,23))
			
			term.setBackgroundColor(WM_COLORS.title_close)
			term.setTextColor(WM_COLORS.title_text)
			term.write("x")
			
			if not process.maximized then
				term.setCursorPos(process.x+process.w-1,process.y+process.h-1)
				term.setBackgroundColor(WM_COLORS.resize_bg)
				term.setTextColor(WM_COLORS.resize_fg)
				term.write(string.char(127))
			end
		end
		process.dirty = 0
	end
end

local function show_menu(items)
	local process = processes[process_current]
	process_set_focus(process_current)
	
	local x = process.x
	local y = process.y
	local w = 0
	local h = #items
	
	for i=1,#items do
		w = math.max(w, #items[i])
	end
	
	local tw, th = term_original.getSize()
	
	if h > th then
		y = 1
		h = th
	elseif y + h > th then
		y = - h + th + 1
		if y < 1 then
			y = 0
			h = th
		end
	end
	if x + w > tw then
		x = - w + tw + 1
	end
	
	process.border = false
	process_reposition(process_current,x,y,w,h)
	
	local selected = 0
	local scroll = 0
	local scroll_min = 0
	local scroll_max = #items-h
	while true do
		term.setBackgroundColor(WM_COLORS.menu)
		term.setTextColor(WM_COLORS.menu_text)
		term.clear()
		
		for i=1,#items do
			term.setCursorPos(1,i-scroll)
			if selected == i then
				term.setBackgroundColor(WM_COLORS.menu_sel)
				term.setTextColor(WM_COLORS.menu_sel_text)
				term.clearLine()
			else
				term.setBackgroundColor(WM_COLORS.menu)
				term.setTextColor(WM_COLORS.menu_text)
			end
			term.write(items[i])
		end
		
		event = {os.pullEvent()}
		
		if event[1] == "key" then
			if event[2] == keys.up then
				selected = math.max(selected-1, 1)
			elseif event[2] == keys.down then
				selected = math.min(selected+1, #items)
			elseif (event[2] == keys.enter or
					event[2] == keys.space) then
				break
			end
		elseif event[1] == "mouse_click" or event[1] == "mouse_drag" then
			selected = event[4]+scroll
		elseif event[1] == "mouse_up" then
			if selected > 0 then break end
		elseif event[1] == "mouse_scroll" then
			scroll = math.min(math.max(scroll + event[2],scroll_min),scroll_max)
		elseif event[1] == "wm_focus" and event[2] == 0 then
			break
		end
		
		local scroll_shift = 0
		if selected == scroll + 1 then
			scroll_shift = -1
		elseif selected == scroll + h then
			scroll_shift = 1
		end
		scroll = math.min(math.max(scroll + scroll_shift,scroll_min),scroll_max)
	end
	if selected > 0 and selected <= #items then
		return selected, items[i]
	else
		return 0, nil
	end
end

local function show_run_menu()
	local options = {"shell","programs...","run...","shutdown","restart"}
	local process = processes[process_current]
	local ret = {pcall(show_menu,options)}
	
	print(ret[1],ret[2])
	if ret[1] then
		if ret[2] == 1 then
			process_run_command(nil,process.x,process.y)
		elseif ret[2] == 2 then
			local progs = shell.programs()
			-- TODO: is pcall necessary here anymore?
			local ret2 = {pcall(show_menu,progs)}
			if ret2[1] and ret2[2] > 0 then
				process_run_command(progs[ret2[2]],process.x,process.y)
			end
		elseif ret[2] == 3 then
			process.border = true
			local x = process.x
			local w = 20
			local tw, th = term_original.getSize()
			
			if x + w - 1 > tw then
				x = tw - w + 1
			end
			
			process_reposition(process_current,x,process.y,w,4)
			process_set_title(process_current,"run")
			
			term.setBackgroundColor(WM_COLORS.run)
			term.setTextColor(WM_COLORS.run_text)
			term.setCursorPos(2,2)
			term.clear()
			term.write("run> ")
			
			local cmd = read(nil,nil,shell.complete)
			if cmd then
				process_run_command(cmd,process.x,process.y)
			end
		elseif ret[2] == 4 then
			os.shutdown()
		elseif ret[2] == 5 then
			os.reboot()
		end
	end
end

-- return true to block click event from the process
local function wm_handle_window_click(id, event)
	local process = processes[id]
	if not process.border then return false end
	if event[4] == process.y then
		if event[2] == 1 then
			if event[3] == process.x + process.w - 1 then
				-- close
				process_end(id)
			elseif event[3] == process.x + process.w - 2 then
				-- maximize
				process_set_maximized(id, not process.maximized)
			elseif event[3] == process.x + process.w - 3 then
				-- minimize
				process_set_visible(id, false)
			elseif not process.maximized then
				drag_state = {}
				drag_state.id = id
				drag_state.mode = DRAG_MOVE
				drag_state.offset = event[3] - process.x
			end
		end
		return true
	elseif event[4] == process.y+process.h-1 and not process.maximized then
		if event[3] == process.x+process.w-1 then
			drag_state = {}
			drag_state.id = id
			drag_state.mode = DRAG_RESIZE
			return true
		end
	end
	return false
end

local function wm_send_mouse_event(id,event)
	local x,y,w,h = process_subwindow_properties(id)
	local proc_event = table_copy(event)
	proc_event[3] = math.min(math.max(proc_event[3] - x + 1,1),w)
	proc_event[4] = math.min(math.max(proc_event[4] - y + 1,1),h)
	queue_event(id,proc_event)
end

local function wm_handle_mouse_event(event)	
	if drag_state then
		if event[1] == "mouse_up" then
			drag_state = nil
		elseif event[1] == "mouse_drag" then
			if drag_state.mode == DRAG_MOVE then
				local process = processes[drag_state.id]
				process_reposition(
					drag_state.id,
					event[3]-drag_state.offset,
					event[4]
				)
			elseif drag_state.mode == DRAG_RESIZE then
				local process = processes[drag_state.id]
				process_reposition(
					drag_state.id,
					process.x,
					process.y,
					math.max(event[3]-process.x+1,MIN_WIDTH),
					math.max(event[4]-process.y+1,MIN_HEIGHT)
				)
			end
		end
		return
	end
	if contains(EVENTS_TOP,event[1]) then
		local hit_window = false
		for i=#processes_visible,1,-1 do
			local id = processes_visible[i]
			local process = processes[id]
			-- event within window borders?
			
			if (process.visible and
				event[3] >= process.x and 
				event[4] >= process.y and 
				event[3] < process.x+process.w and
				event[4] < process.y+process.h) then
				
				hit_window = true
				local x,y,w,h = process_subwindow_properties(id)
				
				local skip = false
				
				if event[1] == "mouse_click" then
					process_set_focus(id,true)
					skip = wm_handle_window_click(id, event)
				end
				
				-- event within window contents?
				if ((not skip) and
					event[3] >= x and 
					event[4] >= y and 
					event[3] < x+w and
					event[4] < y+h) then
					
					wm_send_mouse_event(id,event)
				end
				
				break
			end
		end
		if (not hit_window) and event[1] == "mouse_click" then
			if event[2] == 2 then
				process_create(show_run_menu, "menu", event[3], event[4])
			elseif process_focus > 0 then
				process_set_focus(0)
			end
		end
	else
		if process_focus > 0 then
			wm_send_mouse_event(process_focus,event)
		end
	end
end

local function wm_handle_event(event)
	local is_mouse = contains(EVENTS_MOUSE,event[1])
	local is_keybd = contains(EVENTS_KEYBD,event[1])
	
	if event[1] == "term_resize" then
		w,h = term.getSize()
		for i=1,#processes do
			if processes[i].maximized then
				process_reposition(i,1,1,w,h)
			end
		end
		wm_dirty()
	end
	
	if is_mouse then
		wm_handle_mouse_event(event)
	elseif is_keybd then
		local block = false
		if event[1] == "key" then
			if event[2] == keys.leftCtrl then
				control_held = true
			elseif event[2] == keys.tab and control_held then
				block = true
				if #processes > 0 then
					local new_focus = process_focus + 1
					if new_focus > #processes then
						new_focus = 1
					end
					process_set_visible(new_focus,true)
					process_set_focus(new_focus,true)
				end
			end
		elseif event[1] == "key_up" then
			if event[2] == keys.leftCtrl then
				control_held = false
			end
		end
		if (not block) and process_focus > 0 then
			queue_event(process_focus,event)
		end
	else
		for i=#processes,1,-1 do
			queue_event(i,event)
		end
	end
end

-- draw the background and all windows
local function wm_draw()
	if draw_background then
		term.setBackgroundColor(WM_COLORS.bg)
		term.clear()
		draw_background = false
	end
		
	for i=1,#processes_visible do
		process_draw(processes_visible[i])
	end
	if process_focus > 0 then
		processes[process_focus].window.restoreCursor()
	else
		term.setCursorBlink(false)
	end
end

local function wm_mainloop()
	wm_dirty()
	while true do
		wm_draw()
		evt = {os.pullEventRaw()}
		if evt[1] == "terminate" and process_focus == 0 then
			break
		end
		wm_handle_event(evt)
		while #event_queue > 0 do
			local evt = table.remove(event_queue,#event_queue)
			process_resume(evt[1],evt[2])
		end
	end
end

-- Multishell extensions to provide windowing functionality to programs
multishell_ext.getFocus = function() return process_focus end
multishell_ext.setFocus = function(n) process_set_focus(n) end
multishell_ext.getTitle = function(n) return processes[n].getTitle() end
multishell_ext.setTitle = function(n, title) process_set_title(n, title) end
multishell_ext.getCurrent = function() return process_current end
multishell_ext.getCount = function() return #processes end
multishell_ext.launch = function(tProgramEnv, sProgramPath, ...)
	return process_run(tProgramEnv, sProgramPath, {...})
end
-- TODO: Add more API functions to control window position, size, etc.

-- run a shell window
process_run_command(nil)
process_set_focus(1)

wm_mainloop()

-- cleanup
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1,1)