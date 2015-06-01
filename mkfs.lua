local arg = {...}
if #arg < 1 then
  arg[1] = "-h"
end

--functions
local function numberToBytes(num, size)
  local hex = string.format("%x", num)
  if size and #hex < size*2 then
    while #hex < size*2 do
      hex = ("0"..hex)
    end
  end
  local str = ""
  for i=1, #hex, 2 do
    str = (str..string.char(tonumber(hex:sub(i,i+1), 16)))
  end
  print(num.." -> "..hex..": ", table.unpack(table.pack(str:byte())))
  return str
end

--sets
local verbose = false
local size = false
local fill = false

local jumpCode = 0xEB3C90 --jumpshort(0X3C); NOP; 
local agent = "MKFS.fat"
local sectorSize = 512
local clusterSize = 16
local reservedSectors = 1
local FATNumber = 2
local rootEntries = 512
local mediaDescriptor = 248
local sectorsPerTrack = 1
local heads = 1
local hiddenSectors = 0
local diskID = 0x80
local reserved = 0 --f*ck you NT
--local extended boot signature = nothing
local serial = 0
local name = "NO NAME    "
local code = string.char() --boot code
--local bootsignature = 0xAA55

--args check
for i=1, #arg do
  if arg[i] == "-h" or arg[i] == "--help" then
    print("MKFS help page\n\nUsage: "..(arg[0] or "mkfs")..".<type> [options] [fs-options] device")
    print("\nOPTIONS:")
    print("\t-V --verbose: output debug/state text in the terminal.")
    print("\t-v --version: display version informations.")
    print("\t-h --help: print this message.")
    print("\t-s=<size>, --size=<size>: specify the size of the device.")
    print("\nFAT SPECIFIC OPTIONS:")
    print("\t-C=<size>, --Cluster=<size>: specify the size of a cluster (in sectors).")
    print("\t-S=<size>, --Sector=<size>: specify the size of a sector (in bytes).")
    print("\t-R=<number>, --Reserved=<number>: specify the number of reserved sectors (1 by default).")
    print("\t-B=<number>, --FATNumber=<number>: specify the number of FATs on the disk (2 by default).")
    print("\t-E=<number>, --Entries=<number>: specify the number of entries on the root dir (1 by default).")
    print("\t-T=<hex>, --Type=<hex>: specify the type of disk. (no '0x' on hex)")
    print("\t-N=<string>, --Name=<string>: specify the disk's name (11 characters max) ('NO NAME    ' by default).")
    print("\t-F, --Fill: fill the disk with 0x00 before formating.")
    print("\t-A=<string>, --Agent=<string>: specify the formater name (8 characters max) ('MKFS01LU' by default)")
    print("\n")
    os.exit()
  elseif arg[i] == "-v" or arg[i] == "--version" then
    print("MKFS FAT16 (Lunux) ver.0.1 ")
    os.exit()
  elseif arg[i] == "-V" or arg[i] == "--verbose" then
    verbose = true
  elseif arg[i]:sub(1, 3) == "-s=" or arg[i]:sub(1, 7) == "--size=" then
    size = tonumber(string.match(arg[i], "%d+"))
    if not size then
      print("Invalid size: "..arg[i])
    end
  
  elseif arg[i]:sub(1, 3) == "-C=" or arg[i]:sub(1, 10) == "--Cluster=" then
    clusterSize = tonumber(string.match(arg[i], "%d+"))
    if not clusterSize then
      print("Invalid cluster size: "..arg[i])
    end
  elseif arg[i]:sub(1, 3) == "-S=" or arg[i]:sub(1, 9) == "--Sector" then
    sectorSize = tonumber(string.match(arg[i], "%d+"))
    if not sectorSize then
      print("Invalid sector size: "..arg[i])
    end
  elseif arg[i]:sub(1, 3) == "-N=" or arg[i]:sub(1, 7) == "--Name=" then
    name = string.format("%-11s", string.match(arg[i], "=[%w]+")):sub(2, -1)
    if name == "il" and string.match(arg[i], "=[%w]+") == "nil" then
      print("Invalid name: "..arg[i])
    end
  elseif arg[i]:sub(1, 3) == "-T=" or arg[i]:sub(1, 7) == "--Type=" then
    diskType = tonumber(arg[i]:sub(-2,-1), 16)
    if not diskType then
      print("Invalid disk type: "..arg[i])
    end
  elseif arg[i] == "-F" or arg[i] == "--Fill" then
    fill = true
  
  
  elseif i ~= #arg then
    print("Unrecognised option: "..arg[i])
  end
end

local device = assert(io.open(arg[#arg], "r"))
size = (size or #device:read("*a"))
device:close()

device = io.open(arg[#arg], "w+b")
--Let the fun begin
local sectorNumber = (size/sectorSize)
print(sectorNumber.." sectors in total")
local twoBytesSectors = ((sectorNumber < 65536 and sectorNumber) or 0)
local fourBytesSectors = ((twoBytesSectors == 0 and sectorNumber) or 0)
local hiddenSectors = 0
local clusterNumber = size/(clusterSize*sectorSize)
print(clusterNumber.." clusters in total")
local FATSize = (clusterNumber * 2 / sectorSize)
print(FATSize.." clusters for FAT")

while #code < 448 do code = (code.."\0") end
while #name < 11 do name = (name.." ") end
while #agent < 8 do agent = (agent.."\0") end

if fill then
  for i=1, size do
    device:write("\0")
  end
  device:flush()
  device:seek("set", 0)
end

local BPB = (numberToBytes(jumpCode, 3)..agent..numberToBytes(sectorSize, 2):reverse()..numberToBytes(clusterSize, 1)..numberToBytes(reservedSectors, 2):reverse()..numberToBytes(FATNumber, 1)..numberToBytes(rootEntries, 2):reverse()..numberToBytes(twoBytesSectors, 2):reverse()..numberToBytes(mediaDescriptor, 1)..numberToBytes(FATSize, 2):reverse()..numberToBytes(sectorsPerTrack, 2):reverse()..numberToBytes(heads, 2):reverse()..numberToBytes(hiddenSectors, 4):reverse()..numberToBytes(fourBytesSectors, 4):reverse()..numberToBytes(diskID, 1)..string.char(0)..string.char(0x29)..numberToBytes(serial, 4):reverse()..name.."FAT16   "..code..string.char(0x55, 0xAA))

device:write(BPB)
device:seek("set", sectorSize)
--FAT
for i=1, clusterNumber do
  device:write("\0\0")
end

device:close()
