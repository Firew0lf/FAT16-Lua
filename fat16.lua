-- Warning: in order to work, the library need a "disk" object, which must provide this functions:
-- disk:read(address, [size]): read [size] bytes from <address>
-- disk:write(address, data): write <data> on the disk from the address <address>
-- disk:flush(): save the changes on the disk, if some cache is used
-- 
-- <address> is a value from 0 to sizeOfTheDisk-1

---
-- FAT16 support
-- FAT16 support for Lunux
--
-- @module FAT16
local mod = {}

-- types documentation

---
-- Partition
-- FAT16 partition
-- 
-- @type fatPartition

---
-- BPB
-- FAT16 Boot Paramter Block
-- 
-- @type fatBPB

---
-- Cluster Index
-- FAT16 cluster index in fat
-- 
-- @type fatClusterIndex

---
-- File
-- FAT16 file
-- 
-- @type fatFile

---
-- Directory
-- FAT16 directory
-- 
-- @type fatDirectory

-- local functions

local function bytesToNumber(str)
  local number = 0
  for i=1, #str do
    number = number + (str:sub(i,i):byte() * 2^(8*(i-1)))
  end
  return number
end

---
-- BPB Parser, 
-- Extract the Boot Paramter Block from the disk
-- 
-- @function parseBPB
-- @param #disk disk Disk to extract from
-- @return #fatBPB the disk's BPB
local function parseBPB(disk)
  local raw = disk:read(0, 512)
  if #raw ~= 512 then return nil, "Disk smaller than 512 bytes." end
  local BPB = {
    jump = bytesToNumber(raw:sub(1, 3)),
    formater = raw:sub(4, 11),
    sectorSize = bytesToNumber(raw:sub(12, 13)),
    clusterSize = bytesToNumber(raw:sub(14, 14)),
    reservedSectors = bytesToNumber(raw:sub(15, 16)),
    fatNumber = raw:sub(17, 17):byte(),
    rootEntriesNumber = bytesToNumber(raw:sub(18, 19)),
    twoBytesSectorsNumber = bytesToNumber(raw:sub(20, 21)),
    diskType = raw:sub(22, 22):byte(),
    fatSize = bytesToNumber(raw:sub(23, 24)),
    sectorsPerTrack = bytesToNumber(raw:sub(25, 26)),
    headsNumber = bytesToNumber(raw:sub(27, 28)),
    hiddenSectors = bytesToNumber(raw:sub(29, 32)),
    FourBytesSectorsNumber = bytesToNumber(raw:sub(33, 36)),
    
    diskId = raw:sub(37, 37):byte(),
    reserved = raw:sub(38, 38):byte(),
    signature = raw:sub(39, 39):byte(),
    serial = bytesToNumber(raw:sub(40, 43)),
    diskName = raw:sub(44, 54),
    fatType = raw:sub(55, 62),
    bootCode = raw:sub(63, 510),
    isBootable = (raw:sub(511, 512) == "\x55\xAA"),
  }
  return BPB
end

---
-- FAT interface
-- Return the value of a FAT entry from it's index
-- 
-- @function searchClusterInFAT
-- @param #disk disk Disk to search from
-- @param #fatBPB BPB FAT Infos
-- @param #number index Index of the entry
-- @return #number Value in the entry
local function searchClusterInFAT(disk, BPB, index)
  if (index < 0) or (index > (BPB.fatSize*BPB.sectorSize/2)) then return nil, "Index out of range" end
  local offset = ((BPB.reservedSectors * BPB.sectorSize))
  return bytesToNumber(disk:read(offset+(index*2), 2))
end

local function listFileClusters(partition, start)
  local clusters = {[1] = start}
  while clusters[#clusters] <= 0xFFEF do
    local cluster, err = searchClusterInFAT(partition.disk, partition.BPB, clusters[#clusters])
    if cluster < 0x0002 then return nil, "Corrupted FAT" end
    clusters[#clusters+1] = cluster
  end
  clusters[#clusters] = nil
  if clusters[#clusters] == 0xFFF7 then --bad/hidden cluster
    clusters[#clusters] = nil
  end
  return clusters
end

local function getCluster(disk, BPB, index)
  index = (index - 1)
  local offset = ((BPB.fatSize * BPB.sectorSize * BPB.fatNumber) + (BPB.rootEntriesNumber * 32)) --should be good
  local clusterSize = (BPB.sectorSize * BPB.clusterSize)
  return disk:read(offset + (index * clusterSize), clusterSize)
end

local function parseDirectoryEntry(entry)
  local data = {
    name = entry:sub(1, 8),
    extension = entry:sub(9, 11),
    attributes = entry:sub(12, 12):byte(),
    reserved = entry:sub(13, 13):byte(),
    createTime = entry:sub(14, 16),
    createDate = entry:sub(17, 18),
    accessDate = entry:sub(19, 20),
    accessTime = entry:sub(21, 22),
    modificationTime = entry:sub(23, 24),
    modificationDate = entry:sub(25, 26),
    firstCluster = bytesToNumber(entry:sub(27, 28)),
    size = bytesToNumber(entry:sub(29, 32))
  }
  if data.name:sub(1, 1) == "\0" then
    return nil, "End"
  elseif data.name:sub(1, 1) == "\xE5" then
    return nil, "Deleted"
  end
  if data.attributes == 15 then
    return nil, "Meta-file"
  end
  data.name = data.name:gsub("\x05", "\xE5") --Seriously, "Y did U do dis"
  return data
end

local function getRootDir(partition)
  local offset = (partition.BPB.sectorSize * ((partition.BPB.fatSize * partition.BPB.fatNumber) + 1))
  local list = {}
  local err = false
  for i=1, partition.BPB.rootEntriesNumber do
    list[#list+1], err = parseDirectoryEntry(partition.disk:read(offset + (i*32), 32))
    if not list[i] and err == "End" then
      break
    end
  end
  return list
end

local function getDir(partition, start, size)
  local clusters = listFileClusters(partition, start)
  local data = ""
  for i=1, #clusters do
    data = (data..getCluster(partition.disk, partition.BPB, clusters[i]))
  end
  --data = data:sub(1, (size or #data))
  local entries = {}
  local err
  for i=1, math.floor(#data/32) do
    entries[#entries+1], err = parseDirectoryEntry(data:sub(i*32+1, i*32+32))
    if err == "End" then break end
  end
  return entries
end

local function resolvePath(partition, path)
  --Directory searching part
  local dirs = {}
  local file = false
  for e in string.gmatch(path, "[^/]+") do
    dirs[#dirs+1] = e
  end
  if path:sub(-1,-1) ~= "/" then
    file = dirs[#dirs]
    dirs[#dirs] = nil
  end
  local dir = getRootDir(partition)
  for level = 1, #dirs do
    for i=1, (#dir) do
      if ((dir[i].name.."."..dir[i].extension) == dirs[level]) and (bit32.band(dir[i].attributes, 0x10) == 0x10) then
        dir = getDir(partition, dir[i].firstCluster, dir[i].size)
        i=1 --reset the counter
        break --go to the next level
      elseif i == #dir then
        return nil, ("No such directory: "..dirs[level])
      end
    end
  end
  if not file then
    return (dirs[#dirs] or "/"), dir
  end
  
  --File searching part
  for i=1, #dir do
    if (dir[i].name.."."..dir[i].extension == file) then
      return file, dir[i]
    elseif i==#dir then
      return nil, "No such file"
    end
  end
end

local function searchEmptyCluster(partition)
  for i=2, (BPB.fatSize*BPB.sectorSize/2) do
    if searchClusterInFAT(partition.disk, partition.BPB, i) == 0x0000 then
      return i
    end
  end
  return nil, "FAT Full"
end

local function getFileBytes(file, size, stop) --start from file.seek
  if file.aseek >= file.size then return nil, "End of file" end
  if (file.aseek + size) > file.size then size = (size-(file.size-file.aseek)) end
  local offset =  (file.partition.BPB.sectorSize*((file.partition.BPB.fatSize*file.partition.BPB.fatNumber)+file.partition.BPB.reservedSectors))
  local buff = ""
  for i=1, #file.clusters do print(file.clusters[i]) end
  local clusterSize = (file.partition.BPB.clusterSize * file.partition.BPB.sectorSize)
  
  local zeros = 0
  
  for i=1, size do
    local clusterIndex = math.ceil(file.aseek/clusterSize)
    local cluster = file.clusters[clusterIndex]
    local addr = offset+((clusterSize*cluster)+(file.aseek%clusterSize))
    buff = (buff..file.partition.disk:read(addr, 1))
    if buff:sub(-1,-1):byte() == 0 then zeros = zeros + 1 end
    if stop and buff:sub(-1, -1):match(stop) then break end
    file.aseek = (file.aseek+1)
  end
  print(zeros, "zeros")
  for i=1, #buff do io.write(buff:sub(i, i):byte().."|") end
  return buff
end

-- module functions

function mod.open(partition, path, mode)
  local name, details = resolvePath(partition, path)
  if not name then return nil, details end
  for n,v in pairs(details) do print("", n ,v) end
  local clusters = listFileClusters(partition, details.firstCluster)
  
  local file = {partition=partition, path=path, mode=mode, aseek=1, vbuff="full", buff="", clusters=clusters, size=details.size}
  
  function file.read(self, pattern)
    if type(pattern) == "number" then
      return getFileBytes(self, pattern)
    elseif pattern == "*a" then
      return getFileBytes(self, (self.size-self.aseek))
    elseif pattern == "*l" then
      return getFileBytes(self, self.size, "\n"):sub(1, -2)
    elseif pattern == "*n" then
      return getFileBytes(self, self.size, "[^%d]"):sub(1, -2)
    else
      return nil, "Bad pattern"
    end
  end
  function file.write(self, data)
  
  end
  function file.seek(self, mode, arg)
    if mode == "set" and type(arg) == "number" then
      self.seek = arg
      return self.seek
    elseif mode == "cur" and type(arg) == "number" then
      self.seek = (self.seek + arg)
      return self.seek
    else
      return nil, "Bad mode"
    end
  end
  function file.flush(self)
  
  end
  function file.close(self)
    for n,v in pairs(self) do self[n] = nil end
  end
  function file.setvbuff(self, mode)
  
  end
  
  return file
  
end

function mod.list(self, path, details)
  local data
  path, data = resolvePath(self, path)
  if not path then return nil, data end
  local list = {}
  for n,v in pairs(data) do
    list[n] = {name=string.format("%-8s.%-3s", v.name, v.extension), attributes=v.attributes, size=v.size, isDirectory=(bit32.band(v.attributes, 0x10) == 0x10)}
  end
  return path, ((details and data) or list)
end

function mod.remove(self, path)
  
end

function mod.rename(self, from, to)
  
end

function mod.tmpname(self)
  return (tostring(os.clock()):sub(-8, -1)..".tmp")
end

function mod.mount(self, disk)
  local BPB, err = parseBPB(disk)
  if err then return err end
  local partition = {disk=disk, BPB=BPB, err=err}
  for n,v in pairs(self) do
    partition[n] = v
  end
  return partition
end

function mod.umount(partition)
  partition.disk:flush()
  partition = {disk=partition.disk}
end

mod.resolvePath = resolvePath

return mod