-- See README.md for instructions

-- Some consts
local zeroBit = 0x20000000  -- Always 1
local nadrBit = 0x10000000  -- 1 if value is number, not address
local vnumBit = 0x0fffffff  -- Valid number bit
local adrnBit = 0x200003ff  -- Address ranges
local argcBit = 0x0f000000  -- Number of expected arguments

local codes = {  -- Instruction codes
    goto=0x22000001,  -- Goto VAL1
    ifne=0x24000002,  -- Goto VAL1 if VAL2 ~= VAL3
    ifeq=0x24000003,  -- Goto VAL1 if VAL2 == VAL3
    void=0x22000004,  -- Waits until function finished (e.g. mul) but does nothing with gotten value
    
    copy=0x23000005,  -- Copy VAL1 into VAL2
    
    -- The following output into readable address `boolout`
    band=0x23000008,    -- VAL1 & VAL2
    bor=0x23000009,     -- VAL1 | VAL2
    bxor=0x2300000a,    -- VAL1 ^ VAL2
    blsh=0x2300000b,    -- VAL2 << VAL1             (NOTE THE INVERSION)
    brsh=0x2300000c,    -- VAL2 >> VAL1             (Too much effort to swap them in the computer)
    
    incr=0x2200000d,    -- VAL1++/--                (to `incrout` and `decrout`) 
    
    add=0x2300000e,     -- VAL1 + VAL2              (to `addout`)
    mul=0x2300000f,     -- VAL2 * (VAL1/2^(P/2))    (to `mulout`)
    mulp=0x22000010     -- Sets P for `mul`, allows for lossy fixed-point fractional multiplication
                        --   where the point is after bit P: If P = 8, 1100101 = 1100.101
                        -- Rightshifts an input rather than the output, so low-value detail is clipped
                        --   rather than high-value bits, which are arguably more important
                        -- If low-value bits are important, set P to 1 & rightshift the output manually
}

local addrs = {  -- Address offsets
    ram=0x0,
    rom=0x400,
    io=0xc00
}

local haddr = {  -- Hard-coded addresses for operation outputs
    boolout=0x20000800,     -- Boolean/Bit operations
    incrout=0x20000801,     -- Incremented value
    decrout=0x20000802,     -- Decremented value
    addout=0x20000803,      -- Summed value
    mulout=0x20000804       -- Multiplied value
}

local cmdrw = {  -- Instruction address modes - read/write as address/value
    opRA=0x100,     -- Read from operation & incrementer outs as address
    ramWA=0x200,    -- Write to RAM as address
    ramRV=0x400,    -- Read from RAM as value, don't follow addresses (also when writing!)
    ioRA=0x800,     -- Read from IO as addresses
    aluRA=0x1000    -- Read from ALU outputs as addresses
}

local errors = {}

local linux_env = os.getenv("HOME")


function validate_num (num, numMode)
    local num = bit.bor(bit.band(num, vnumBit), zeroBit)  -- Ensure only 0x20000000 is on and not 0x10000000
    
    if numMode == true then num = bit.bor(num, nadrBit)  -- If not address, add 0x10000000
    else num = bit.band(num, adrnBit) end  -- If address, mask to 0x3ff
    return num
end


function parse_line (line, filts, gotos, aboveTags, consts, romConsts)
    local cmdParts = {}
    -- Separate command/arguments by space
    for cmd in string.gmatch(line, "[^ ]+") do table.insert(cmdParts, cmd) end
    
    if cmdParts[1] ~= "--" and #cmdParts ~= 0 then  -- Ignore comments and empty lines
        if string.match(cmdParts[1], "^%$[A-z0-9_]+$") then  -- Check for constant declaration
            if consts[cmdParts[1]] ~= nil then table.insert(errors, "Duplicate constant declaration: " .. cmdParts[1]) end
            consts[cmdParts[1]] = parse_arg(cmdParts[2])
        elseif string.match(cmdParts[1], "^?[A-z0-9_]+$") then  -- Check for ROM constant declaration
            if romConsts[cmdParts[1]] ~= nil then table.insert(errors, "Duplicate ROM constant declaration: " .. cmdParts[1]) end
            romConsts[cmdParts[1]] = parse_arg(cmdParts[2])
        elseif string.match(cmdParts[1], "^:[A-z0-9_]+$") then  -- Check for goto tag
            table.insert(aboveTags, cmdParts[1])
        else
            -- Set goto tags above this line to this line
            for _, tag in pairs(aboveTags) do
                if gotos[tag] ~= nil then table.insert(errors, "Duplicate tag declaration: " .. tag) end
                gotos[tag] = #filts
            end
            aboveTags = {}  -- Clear above tags
            local filtCodes = parse_cmd(cmdParts)
            for _, filt in pairs(filtCodes) do table.insert(filts, filt) end
        end
    end
    
    return filts, gotos, aboveTags, consts, romConsts
end


function parse_cmd (cmdParts)
    local parts = {}
    for i, s in pairs(cmdParts) do
        if i == 1 then
            -- Parse the first argument as command
            local c = parse_code(s)
            if c ~= 0 then
                local argc = bit.rshift(bit.band(c, argcBit), 0x18)
                if argc ~= #cmdParts then table.insert(errors, "Expected " .. (argc - 1) .. " arguments: " .. table.concat(cmdParts, " ")) end
            end
            table.insert(parts, c)
        else
            -- Parse the rest as arguments
            table.insert(parts, parse_arg(s))
        end
    end
    return parts
end


function parse_string (arg)
    local concat = 0
    local len = 0
    
    for str in string.gmatch(arg, "[^,]+") do
        if len >= 3 then
            table.insert(errors, "Too many parts: " .. arg)
            return 0
        end
        
        if string.match(str, "^\".\"$") then
            concat = bit.bor(bit.lshift(concat, 8), string.byte(str, 2))
        elseif tonumber(str) then
            concat = bit.bor(bit.lshift(concat, 8), tonumber(str))
        else
            table.insert(errors, "Could not resolve: " .. arg)
            return 0
        end
        len = len + 1
    end
    
    return concat
end


function parse_code (code)
    local c = 0
    local writtenCmd = false
    -- Separate/Combine instruction and address modes
    for str in string.gmatch(code, "[^,]+") do
        if codes[str] ~= nil then
            if not writtenCmd then
                c = bit.bor(c, codes[str])
                writtenCmd = true
            else
                table.insert(errors, "Multiple commands used: " .. code)
                return 0
            end
        elseif cmdrw[str] ~= nil then c = bit.bor(c, cmdrw[str])
        else
            table.insert(errors, "Unknown command or mask: " .. str)
            return 0
        end
    end
    return c
end


function parse_arg (arg)
    -- If argument is goto label or constant, return as-is to be resolved later
    if string.match(arg, "^[:$?][A-z0-9_]+$") then return arg end
    
    -- If argument is just key word, return that
    if haddr[arg] ~= nil then return haddr[arg] end
    
    parts = {}
    for s in string.gmatch(arg, "[^@]+") do table.insert(parts, s) end
    -- If argument is just a number or character, treat as value and not address
    if parts[2] == nil then 
        -- Up to 3 comma separated values are combined into 1 number, for strings
        return validate_num(parse_string(parts[1]), true)
    else
        -- If offset included in argument, use as address
        if tonumber(parts[1]) and addrs[parts[2]] then return bit.bor(validate_num(tonumber(parts[1]), false), addrs[parts[2]]) end
    end
    
    table.insert(errors, "Could not resolve number or offset: " .. arg)
    return 0
end


function append_romConsts (filts, romConsts)
    local f = #filts
    local addresses = {}
    local e = 0
    for name, val in pairs(romConsts) do
        table.insert(filts, val)
        addresses[name] = bit.bor(validate_num(e + f, false), addrs.rom)
        e = e + 1
    end
    return filts, addresses
end


function resolve_tags (filts, gotos, consts, romConstAddrs)
    for f = 1, #filts do
        if type(filts[f]) == "string" then
            -- Replace tags and constants with their values
            if string.match(filts[f], "^:[A-z0-9_]+$") then
                if gotos[filts[f]] then filts[f] = validate_num(bit.band(gotos[filts[f]], adrnBit), true)
                else table.insert(errors, "Missing tag declaration: " .. filts[f]) end
            elseif string.match(filts[f], "^%$[A-z0-9_]+$") then
                if consts[filts[f]] then filts[f] = consts[filts[f]]
                else table.insert(errors, "Missing constant declaration: " .. filts[f]) end
            elseif string.match(filts[f], "^?[A-z0-9_]+$") then
                if romConstAddrs[filts[f]] then filts[f] = romConstAddrs[filts[f]]
                else table.insert(errors, "Missing ROM constant declaration: " .. filts[f]) end
            end
        end
    end
    return filts
end


function file_exists (file)
    local f = io.open(file, "rb")
    if f then f:close() end
    if f == nil then
        tpt.log("\nFailed to load file")
    end
    return f ~= nil
end


function lines_from (file)  -- Reads everything from a file
    if not file_exists(file) then return nil end
    local lines = {}
    if debug_mode then tpt.log("\nReading") end
    for line in io.lines(file) do
        table.insert(lines, line)
    end

    return lines
end


function parse (file)
    local filts = {}
    local gotos = {}
    local aboveTags = {}
    local consts = {}
    local romConsts = {}
    local romConstAddrs = {}
    local lines = lines_from(file)
    
    
    for _, line in pairs(lines) do
        filts, gotos, aboveTags, consts, romConsts = parse_line(line, filts, gotos, aboveTags, consts, romConsts)
        if #filts > 1024 or #gotos > 1024 or #aboveTags > 1024 or #consts > 1024 or #romConsts > 1024 then
            table.insert(errors, "Out of space!")
            break
        end
    end
    
    if #aboveTags ~= 0 then
        table.insert(errors, "Trailing goto tags: " .. table.concat(aboveTags, ", "))
    end
    
    filts, romConstAddrs = append_romConsts(filts, romConsts)
    
    filts = resolve_tags(filts, gotos, consts, romConstAddrs)
    
    return filts
end


function find_anchor ()  -- Finds INVS pixel for use as a positional anchor
    tpt.start_getPartIndex()

    while tpt.next_getPartIndex() do
        local i = tpt.getPartIndex()
        if tpt.get_property("type", i) == tpt.element("INVS") then  -- and tpt.get_property("ctype", i) == 69420 then
            tpt.set_property("type", tpt.element("STOR"), i)
            return tpt.get_property("x", i), tpt.get_property("y", i)
        end
    end

    table.insert(errors, "Could not find computer to program")
    return nil
end


function encode_filts (filts)
    local ax, ay
    ax, ay = find_anchor()
    
    if not ax or not ay then return end
    
    ax = ax + 1
    ay = ay - 15
    
    for f, filt in pairs(filts) do
        local xx, yy
        xx = ax + math.floor((f - 1) / 16)
        yy = ay + ((f - 1) % 16)
        tpt.set_property("ctype", filt, xx, yy)
    end
end


function encode (file)
    local filts = parse(file)
    if #errors ~= 0 then
        tpt.log("Errors occured!")
        return
    end
    tpt.log("Successfuly parsed " .. #filts .. " FILTs")
    errors = {}
    
    encode_filts(filts)
end



local current_path = ""
local current_files = {}
local gui_scroll = 0
local gui_scroll_max = 0
local gui_selection = 0
local brush_modes = {0, 0, 0, 0, 0}

function get_parent (path)
    local up = ""
    local delim = ""
    if linux_env then
        delim = "/"
        up = "/"
    else
        delim = "\\"
    end
    
    local path_split = split_path(path)
    
    for i, p in pairs(path_split) do  -- or (i == 1 and up == "")
        if i < #path_split then up = up .. p .. delim end
    end
    
    return up
end


function split_path (path)
    local path_parts = {}
    for part in string.gmatch(path, "[^/^\\]+") do table.insert(path_parts, part) end
    return path_parts
end


function get_files (path)
    local files = {{name = "..", path = get_parent(path), folder = true}}
    
    if linux_env then
        -- Linux commands
        local names = io.popen("ls -dp \"" .. path .. "\"*")
        
        for file in names:lines() do
            local path_parts = split_path(file)
            table.insert(files, {name = path_parts[#path_parts], path = file, folder = string.match(file, ".*/$") and true or false})
        end
    else
        -- Windows commands
        if path ~= "" then
            local folder_names = io.popen("dir \"" .. path .. "\" /b /ad")
            local file_names = io.popen("dir \"" .. path .. "\" /b /a-d")
            local path_parts = split_path(path)
            
            for folder in folder_names:lines() do
                table.insert(files, {name = folder, path = table.concat(path_parts, "\\") .. "\\" .. folder .. "\\", folder = true})
            end
            for file in file_names:lines() do
                table.insert(files, {name = file, path = table.concat(path_parts, "\\") .. "\\" .. file, folder = false})
            end
        else
            for _, drive in pairs({"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"}) do
                local drive_root = drive .. ":\\"
                
                for d in io.popen("dir " .. drive_root .. " /b /ad"):lines() do
                    table.insert(files, {name = drive_root, path = drive_root, folder = true})
                    break
                end
            end
        end
    end
    
    return files
end


function select_gui_path (path)  -- Opens a directory for the file gui to display
    current_path = path
    current_files = get_files(current_path)
    gui_scroll = 0
    gui_scroll_max = math.max(math.ceil(#current_files / 2) * 12 - 12 * 21 - 1, 0)
end


function open_file_gui (path)  -- Registers GUI to run every tick
    local delim = linux_env and "/" or "\\"
    path = (linux_env and "/" or "") .. table.concat(split_path(path), delim) .. delim
    
    tpt.set_console(0)
    brush_modes = {tpt.brushx, tpt.brushy, tpt.selectedl, tpt.selectedr, tpt.selecteda}
    select_gui_path(path)
    event.register(event.tick, file_gui)
    event.register(event.mouseup, click_handler)
    event.register(event.mousewheel, scroll_handler)
end


function close_file_gui ()  -- Unregisters GUI and sets mouse selections back
    event.unregister(event.tick, file_gui)
    event.unregister(event.mouseup, click_handler)
    event.unregister(event.mousewheel, scroll_handler)
    tpt.hud(1)
    event.register(event.tick, delay_mouse_reset)
end


function delay_mouse_reset ()
    event.unregister(event.tick, delay_mouse_reset)
    tpt.brushx = brush_modes[1]
    tpt.brushy = brush_modes[2]
    tpt.selectedl = brush_modes[3]
    tpt.selectedr = brush_modes[4]
    tpt.selecteda = brush_modes[5]
    
    if #errors ~= 0 then
        local file_split = split_path(current_files[gui_selection].path)
        local file_name = file_split[#file_split]
        if tpt.confirm("Errors occured", "Could not compile file: " .. file_name, "Show errors") then
            tpt.throw_error(table.concat(errors, "\n"))
        end
    end
    
    errors = {}
end


function file_gui ()  -- Shows a GUI for the user to select a script
    tpt.hud(0)
    tpt.set_pause(1)
    tpt.brushx = 0
    tpt.brushy = 0
    tpt.selectedl = "DEFAULT_UI_SAMPLE"
    tpt.selectedr = "DEFAULT_UI_SAMPLE"
    tpt.selecteda = "DEFAULT_UI_SAMPLE"

    tpt.fillrect(0, 0, 628, 424, 0, 0, 0, 96)
    tpt.drawrect(100, 50, 428, 324)
    tpt.fillrect(100, 50, 428, 324, 0, 0, 0)

    if debug_mode then tpt.drawtext(450, 60, "DEBUG MODE", 255, 96, 96) end
    tpt.drawtext(110, 60, "Select a script to compile...")
    tpt.drawtext(110, 75, "    " .. (not linux_env and current_path == "" and "My Computer" or current_path), 127, 127, 255)
    tpt.drawrect(105, 90, 418, 279, 200, 200, 200)

    gui_selection = 0
    for index, file in pairs(current_files) do
        local x_pos = 115 + (index - 1) % 2 * 201
        local y_pos = 100 + math.floor((index - 1) / 2 + 1) * 12 - gui_scroll
        local hovering = tpt.mousex > x_pos and tpt.mousex < x_pos + 201 and tpt.mousey > y_pos and tpt.mousey < y_pos + 12
        if file.folder then folder_col = 1 else folder_col = 0 end

        if y_pos >= 95 and y_pos < 358 then
            if hovering then
                gui_selection = index
                tpt.fillrect(x_pos - 2, y_pos - 2, 201, 12, 255, 255, 255)
                tpt.drawtext(x_pos, y_pos, file.name, 0, 0, folder_col * 127)
            else
                tpt.drawtext(x_pos, y_pos, file.name, 255 - folder_col * 128, 255 - folder_col * 128, 255)
            end
        end
    end

    if tpt.mousey > 350 and tpt.mousey < 370 then  -- Scrolling by putting the mouse at the top or bottom of the display
        gui_scroll = gui_scroll + ((tpt.mousey - 350) / 5) ^ 1.5
    end
    if tpt.mousey > 90 and tpt.mousey < 110 then
        gui_scroll = gui_scroll - ((110 - tpt.mousey) / 5) ^ 1.5
    end

    if gui_scroll < 0 then gui_scroll = gui_scroll + (-gui_scroll / 5) ^ 2 / 5 end
    if gui_scroll > gui_scroll_max then gui_scroll = gui_scroll - ((gui_scroll - gui_scroll_max) / 5) ^ 2 / 5 end
end


function click_handler ()
    if tpt.mousex < 100 or tpt.mousex > 528 or tpt.mousey < 50 or tpt.mousey > 374 then close_file_gui() end

    if gui_selection ~= 0 then
        if current_files[gui_selection].folder then
            select_gui_path(current_files[gui_selection].path)
        else
            tpt.log(current_files[gui_selection].path)
            encode(current_files[gui_selection].path)
            close_file_gui()
        end
    end
end


function scroll_handler (x, y, d)
    gui_scroll = gui_scroll - d * 12
end