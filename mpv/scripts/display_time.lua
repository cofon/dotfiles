function show_time()
    local time_str = os.date("%Y-%m-%d %H:%M:%S")
    mp.commandv("show-text", time_str, 3000)
end

mp.register_script_message("display-time", show_time)
