#! ../../bin/lua

-------------------------------------------------------------------------------
-- Name:        bin2c.lua
-- Purpose:     Converts files into const unsigned char* C strings
-- Author:      John Labenski
-- Created:     2005
-- Copyright:   (c) 2005 John Labenski
-- Licence:     wxWidgets licence
-------------------------------------------------------------------------------
-- This program converts a file into a "const unsigned char" buffer and a
--   size_t length for use in a C/C++ program. It requires lua >= 5.1 to run.
--
-- It outputs to the console so no files are modified, use pipes to redirect
--   or -o command line option to write to a specified file.
--
-- See "Usage()" function for usage or just run this with no parameters.
--
-- The program has two modes, binary and text.
--   In text mode; each line of the char buffer is each line in the input file.
--      This will minimize the diffs for small changes in files put into CVS.
--   In binary mode (default), the file is dumped 80 cols wide as is.
-------------------------------------------------------------------------------

-- formatted print statement
function printf(...)
    io.write(string.format(unpack(arg)))
end

-- simple test to see if the file exits or not
function FileExists(filename)
    local file = io.open(filename, "r")
    if (file == nil) then return false end
    io.close(file)
    return true
end

-- Do the contents of the file matche the strings in the fileData table?
--   The table may contain any number of \n per index.
--   Returns true for an exact match or false if not.
function FileDataIsTableData(filename, fileData)
    local file_handle = io.open(filename)
    if not file_handle then return false end -- ok if it doesn't exist

    for n = 1, #fileData do
        local line = fileData[n]
        local len = string.len(line)
        local file_line = file_handle:read(len)

        if line ~= file_line then
            io.close(file_handle)
            return false
        end
    end

    local cur_file_pos = file_handle:seek("cur")
    local end_file_pos = file_handle:seek("end")
    io.close(file_handle)

    if cur_file_pos ~= end_file_pos then return false end -- file is bigger

    return true
end

-- Write the contents of the table fileData (indexes 1.. are line numbers)
--  to the filename, but only write to the file if FileDataIsTableData returns
--  false. If overwrite_always is true then always overwrite the file.
--  returns true if the file was overwritten
function WriteTableToFile(filename, fileData, overwrite_always)
    assert(filename and fileData, "Invalid filename or fileData in WriteTableToFile")

    if (not overwrite_always) and FileDataIsTableData(filename, fileData) then
        print("bin2c.lua - No changes to file : '"..filename.."'")
        return false
    end

    print("bin2c.lua - Updating file : '"..filename.."'")

    local outfile = io.open(filename, "w+")
    if not outfile then
        print("Unable to open file for writing '"..filename.."'.")
        return false
    end

    for n = 1, #fileData do
        outfile:write(fileData[n])
    end

    outfile:flush()
    outfile:close()
    return true
end

-- Read a file as binary data, returning the data as a string.
function ReadBinaryFile(fileName)
    local file = assert(io.open(fileName, "rb"),
                        "Invalid input file : '"..tostring(fileName).."'\n")
    local fileData = file:read("*all")
    io.close(file)
    return fileData
end

-- Create the output header and prepend to the outTable
function CreateHeader(stringName, is_static, fileName, fileSize, outTable)
    local headerTable = {}

    table.insert(headerTable, "/* Generated by bin2c.lua and should be compiled with your program.  */\n")

    if (not is_static) then
        table.insert(headerTable, "/* Access with :                                                     */\n")
        table.insert(headerTable, "/*   extern const size_t stringname_len; (excludes terminating NULL) */\n")
        table.insert(headerTable, "/*   extern const unsigned char stringname[];                        */\n\n")
    else
        table.insert(headerTable, "/* #include this header in your C/C++ code to use the array.         */\n\n")
    end

    table.insert(headerTable, "#include <stdio.h>   /* for size_t */\n\n")

    table.insert(headerTable, string.format("/* Original filename: '%s' */\n", fileName))

    if (not is_static) then
        table.insert(headerTable, string.format("extern const size_t %s_len;\n", stringName)) -- force linkage
        table.insert(headerTable, string.format("extern const unsigned char %s[];\n\n", stringName))

        table.insert(headerTable, string.format("const size_t %s_len = %d;\n", stringName, fileSize))
        table.insert(headerTable, string.format("const unsigned char %s[%d] = {\n", stringName, fileSize+1))
    else
        table.insert(headerTable, string.format("static const size_t %s_len = %d;\n", stringName, fileSize))
        table.insert(headerTable, string.format("static const unsigned char %s[%d] = {\n", stringName, fileSize+1))
    end

    -- prepend the header to the outTable in reverse order
    for n = #headerTable, 1, -1 do
        table.insert(outTable, 1, headerTable[n])
    end

    return outTable
end

-- Dump the data for the text file maintaining the original line structure
function CreateTextData(fileData, outTable, line_ending)
    local CR  = string.byte("\r") -- DOS = CRLF, Unix = LF, Mac = CR
    local LF  = string.byte("\n")
    local file_len = string.len(fileData)
    local len = 0
    local n   = 1
    local str = ""

    if line_ending then
        local switch = {
            cr   = string.format("%3u,", CR),
            lf   = string.format("%3u,", LF),
            crlf = string.format("%3u,%3u,", CR, LF) }

        line_ending = switch[string.sub(line_ending, 2)] -- remove leading '-'
    end

    while ( n <= file_len ) do
        local byte = string.byte(fileData, n)

        if (byte == CR) or (byte == LF) then
            local line_end_str = string.format("%3u,", byte)

            -- handle DOS CRLF line endings by adding the LF before new line
            if (byte == CR) and (n < file_len) and (string.byte(fileData, n+1) == LF) then
                n = n + 1
                line_end_str = line_end_str..string.format("%3u,", LF)
            end

            -- replace with user specified line ending
            if line_ending ~= nil then
                line_end_str = line_ending
            end

            str = str..line_end_str
            len = len + math.floor(string.len(line_end_str)/4)
        else
            str = str..string.format("%3u,", byte)
            len = len + 1
        end

        -- add a real \n to text file, will be appropriate for platform
        if (byte == CR) or (byte == LF) or (n >= file_len) then
            table.insert(outTable, str.."\n")
            str = ""
        end

        n = n + 1
    end

    table.insert(outTable, "  0 };\n\n")
    return outTable, len
end

-- Dump the binary data 20 bytes at a time so it's 80 chars wide
function CreateBinaryData(fileData, outTable)
    local count = 0
    local len = 0
    local str = ""
    for n = 1, string.len(fileData) do
        str = str..string.format("%3u,", string.byte(fileData, n))
        len = len + 1
        count = count + 1
        if (count == 20) then
            table.insert(outTable, str.."\n")
            str = ""
            count = 0
        end
    end

    table.insert(outTable, str.."\n  0 };\n\n")
    return outTable, len
end

-- Print the Usage to the console
function Usage()                                                                     -- | 80 col
  print("bin2c.lua converts a file to const unsigned char byte array for loading with")
  print("  lua_dobuffer or for general use by any C/C++ program.\n")
  print("The output contains two variables, the data size and the data itself.")
  print("  const size_t stringname_len; // string length - 1 (excludes terminating NULL)")
  print("  const unsigned char stringname[] = { 123, 232, ... , 0 }; ")
  print("When converting text files you may want to use the -lf switch since many")
  print("  programs can easily parse Unix line endings and the output will be the same")
  print("  no matter what line endings the original file has. This is useful for")
  print("  files checked out using CVS on both Unix and DOS platforms.")
  print("Switches :")
  print("  -b    Binary dump for binary files, 80 columns wide (default)")
  print("  -t    Text dump where the original line structure is maintained")
  print("  -cr   Convert line endings to carriage returns CR='\\r' for Mac (use with -t)")
  print("  -lf   Convert line endings to line feeds LF='\\n' for Unix (use with -t)")
  print("  -crlf Convert line endings to CRLF='\\r\\n' for DOS (use with -t)")
  print("  -n    Name of the c string to create, else derive name from input file")
  print("  -s    Add the 'static' keyword to the const char array")
  print("  -o    Filename to output to, else output to stdout")
  print("  -w    When used with -o always overwrite the output file")
  print("Usage : ")
  print("  $lua.exe bin2c.lua [-b or -t] [-cr or -lf or -crlf] [-n cstringname]")
  print("                     [-o outputfile.c] [-w] inputfile")
end

-- The main() program to run
function main()

    local is_text     = false  -- -t switch set
    local is_binary   = false  -- -b switch set
    local line_ending = nil    -- -cr, -lf, -crlf switches
    local set_string  = false  -- -n switch set
    local stringName  = nil    -- -n stringName
    local is_static   = false  -- -s switch set
    local output_file = false  -- -o switch set
    local outFileName = nil    -- -o fileName
    local overwrite   = false  -- -w
    local inFileName  = nil    -- input filename

    local n = 1
    while n <= #arg do
        if (arg[n] == "-t") or (arg[n] == "/t") then
            is_text   = true
        elseif (arg[n] == "-b") or (arg[n] == "/b") then
            is_binary = true
        elseif (arg[n] == "-cr") or (arg[n] == "/cr") then
            line_ending = (line_ending or "").."-cr" -- to check errors
        elseif (arg[n] == "-lf") or (arg[n] == "/lf") then
            line_ending = (line_ending or "").."-lf"
        elseif (arg[n] == "-crlf") or (arg[n] == "/crlf") then
            line_ending = (line_ending or "").."-crlf"
        elseif (arg[n] == "-w") or (arg[n] == "/w") then
            overwrite = true
        elseif (arg[n] == "-n") or (arg[n] == "/n") then
            set_string = true
            n = n + 1
            stringName = arg[n]
        elseif (arg[n] == "-s") or (arg[n] == "/s") then
            is_static = true
        elseif (arg[n] == "-o") or (arg[n] == "/o") then
            output_file = true
            n = n + 1
            outFileName = arg[n]
        elseif n == #arg then
            -- input filename is always the last parameter
            inFileName = arg[n]
        end

        n = n + 1
    end

    -- check for simple errors, like missing or extra parameters
    if #arg < 1 then
        Usage()
        return
    end
    if (is_text and is_binary) then
        print("Error: Only use -b or -t flags, not both.\n")
        Usage()
        return
    end
    if (is_binary and line_ending) then
        print("Error: Only use -cr, -lf, -crlf with text file -t flag, not -b binary.\n")
        Usage()
        return
    end
    if not ((line_ending == nil) or (line_ending == "-cr") or
            (line_ending == "-lf") or (line_ending == "-crlf")) then
        print("Error: Only use one of -cr, -lf, -crlf at a time.\n")
        Usage()
        return
    end
    if (set_string and (not stringName)) then
        print("Error: Missing name of the string to use for -n flag.\n")
        Usage()
        return
    end
    if (output_file and (not outFileName)) then
        print("Error: Missing output filename to use for -o flag.\n")
        Usage()
        return
    end

    if (not inFileName) or (not FileExists(inFileName)) then
        print("Error: Invalid or missing input filename : '"..tostring(inFileName).."'\n")
        Usage()
        return
    end

    local inFileName_ = inFileName

    -- handle the name to use for the char buffer if not set on command line
    if stringName == nil then
        -- remove unix path, if any, of the input filename
        --   note: string.find only can search forward
        local n = string.find(inFileName_, "/", 1, 1)
        while n do
            inFileName_ = string.sub(inFileName_, n+1)
            n = string.find(inFileName_, "/", 1, 1)
        end
        -- remove DOS path, if any, of the input filename
        local n = string.find(inFileName_, "\\", 1, 1)
        while n do
            inFileName_ = string.sub(inFileName_, n+1)
            n = string.find(inFileName_, "\\", 1, 1)
        end

        -- replace invalid C variable name chars in C with '_' for the string name based on the filename
        -- if they don't like the results they can always set the filename on the command line
        stringName = string.gsub(inFileName_, "[`~!@#$%%^&*()%-+={%[}%]|:;\"'<,>.? ]", "_")
    end

    local fileData = ReadBinaryFile(inFileName)
    local outTable = {}
    local len = 0

    if is_text then
        outTable, len = CreateTextData(fileData, outTable, line_ending)
    else -- default is binary
        outTable, len = CreateBinaryData(fileData, outTable)
    end

    outTable = CreateHeader(stringName, is_static, inFileName_, len, outTable)

    if not output_file then
        for n = 1, #outTable do
            printf(outTable[n])
        end
    else
        WriteTableToFile(outFileName, outTable, overwrite)
    end

end

main()
