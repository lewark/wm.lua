while true do
    local evt, msg = os.pullEvent("wm_log")
    print(msg)
end
