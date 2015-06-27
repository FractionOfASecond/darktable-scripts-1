dt = require "darktable"

local exif_date_pattern = "^(%d+):(%d+):(%d+) (%d+):(%d+):(%d+)"

--https://www.darktable.org/usermanual/ch02s03.html.php#supported_file_formats
local supported_image_formats_init = {"3FR", "ARW", "BAY", "BMQ", "CAP", "CINE",
"CR2", "CRW", "CS1", "DC2", "DCR", "DNG", "ERF", "FFF", "EXR", "IA", "IIQ",
"JPEG", "JPG", "K25", "KC2", "KDC", "MDC", "MEF", "MOS", "MRW", "NEF", "NRW",
"ORF", "PEF", "PFM", "PNG", "PXN", "QTK", "RAF", "RAW", "RDC", "RW1", "RW2",
"SR2", "SRF", "SRW", "STI", "TIF", "TIFF", "X3F"}

-------- Configuration --------

local mount_root = "/Volumes"
local alternate_inbox_name = "Inbox"
local alternate_dests = {
  --nil = using the preference setting for folder structure
  --{"/Users/ThePhotographer/Pictures/Darktable", nil},
  
  --folder structure setting overridden for this destination:
  --{"/Users/ThePhotographer/Pictures/Darktable specials", "${year}/${month}"},
}

local using_multiple_dests = (#alternate_dests > 0)

local supported_image_formats = {}
for index,ext in pairs(supported_image_formats_init) do
  supported_image_formats[ext] = true
end

-------- Support functions --------

local function interp(s, tab)
  local sstring = (s:gsub('($%b{})', function(w) return tab[w:sub(3, -2)] or w end))
  if (string.find(sstring, "${")) then
    dt.print (s.." contains an unsupported variable. Remove it, try again!")
    assert (false)  
  end
  
  return sstring
end
getmetatable("").__mod = interp

local function escape_path(path)
  return string.gsub(path, " ", "\\ ")
end

local function split_path(path)
  return string.match(path, "(.-)([^\\/]-%.?([^%.\\/]*))$")
end

local function on_same_volume(absPathA, absPathB)
  local mountedVolumePattern = "^"..mount_root.."/(.-)/"
  
  local rootA = string.match(absPathA, mountedVolumePattern)
  if (rootA == nil) then
    rootA = absPathA:sub(1,1)
    assert(rootA == "/")
  end
  
  local rootB = string.match(absPathB, mountedVolumePattern)
  if (rootB == nil) then
    rootB = absPathB:sub(1,1)
    assert(rootB == "/")
  end
  
  local isSameVolume = (rootA == rootB)
  return isSameVolume
end

-------- import_transaction class --------

local import_transaction = {
  type = nil,
  srcPath = nil,
  destRoot = nil,
  destStructure = nil,
  destPath = nil,
  date = nil,
  tags = nil,
  destFileExists = nil
}

import_transaction.__index = import_transaction

function import_transaction.new(path, destRoot)
  local self = setmetatable({}, import_transaction)
  self.srcPath = path
  self.destRoot = destRoot
  return self
end

function import_transaction.load(self)
  --check if supported image file or movie, set self.type to 'image' or
  --'movie' or 'none' otherwise
  assert(self.srcPath ~=nil)
  assert(self.destRoot ~= nil)
  local dir, name, ext = split_path(self.srcPath)
  
  
  if (ext ~= nil and supported_image_formats[ext:upper()] == true) then
    self.type = 'image'
    self.tags = {}
    
    for exifLine in io.popen("exiftool -n -s -Time:all '"..self.srcPath.."'"):lines() do
      local tag, value = string.match(exifLine, "([%a ]-)%s+: (.-)$")
      if (tag ~= nil) then
        self.tags[tag] = value
      end
    end
    
    local exifDateTag = self.tags['DateTimeOriginal']
    if (exifDateTag == nil) then
      exifDateTag = self.tags['CreateDate']
    end
    if (exifDateTag == nil) then
      exifDateTag = self.tags['ModifyDate']
    end
    if (exifDateTag == nil) then
      exifDateTag = self.tags['FileModifyDate']
    end
    assert (exifDateTag ~= nil)
    
    local date = {}
    date['year'], date['month'], date['day'], date['hour'], date['minute'], date['seconds']
      = exifDateTag:match(exif_date_pattern)
    self.date = date
    
    local dirStructure = _copy_import_default_folder_structure
    if (self.destStructure ~= nil) then
      dirStructure = self.destStructure
    end
    self.destPath = interp(self.destRoot.."/"..dirStructure.."/"..name, self.date)
  end
end

function import_transaction.copy_image(self)
  assert (self.destPath ~= nil)
  assert (self.tags ~= nil)
  assert (self.date ~= nil)
  assert (self.type == 'image')
  
  local destDir,_,_ = split_path(self.destPath)
  
  local makeDirCommand = "mkdir -p '"..destDir.."'"
  
  local testIsFileCommand = "test -s '"..self.destPath.."'"
  local testIsNotFileCommand = "test ! -s '"..self.destPath.."'"
  
  local fileExists = os.execute(testIsFileCommand)
  local fileNotExists = os.execute(testIsNotFileCommand)

  assert(fileExists ~= fileNotExists)
  
  if (fileExists == nil) then
    local copyMoveCommand = "cp -n '"..self.srcPath.."' '"..self.destPath.."'"
    if (on_same_volume(self.srcPath,self.destPath)) then
      copyMoveCommand = "mv -n '"..self.srcPath.."' '"..self.destPath.."'"
    end
    
    --print (makeDirCommand)
    coroutine.yield("RUN_COMMAND", makeDirCommand)
    
    --print (copyCommand)
    coroutine.yield("RUN_COMMAND", copyMoveCommand)
  else
    destDir = nil
  end
  
  self.destFileExists = true
  
  return destDir
end

-------- Subroutines --------

local function scrape_files(scrapeRoot, destRoot, structure, list)
  local numFilesFound = 0
  for imagePath in io.popen("ls "..scrapeRoot.."/*.*"):lines() do
    local trans = import_transaction.new(imagePath, destRoot)
    --Preference value will be used if nil
    trans.destStructure = structure
    
    table.insert(list, trans)
    numFilesFound = numFilesFound + 1
  end
  
  return numFilesFound
end

-------- Main function --------

function copy_import()
  local statsNumImagesFound = 0
  local statsNumImagesDuplicate = 0
  local statsNumFilesFound = 0
  local statsNumFilesCopied = 0
  local statsNumFilesScanned = 0
  
  local dcimDestRoot = nil
  if(using_multiple_dests) then
    dcimDestRoot = dt.preferences.read("copy_import","DCFImportDirectorySelect","enum")
  else
    dcimDestRoot = dt.preferences.read("copy_import","DCFImportDirectoryBrowse","directory")
  end
  _copy_import_default_folder_structure = dt.preferences.read("copy_import","FolderPattern", "string")
    
  transactions = {}
  changedDirs = {}
  
  local testDestRootMounted = "test -d '"..dcimDestRoot.."'"
  local destMounted = os.execute(testDestRootMounted)
  
  --Handle DCF (flash card) import
  if (destMounted == true) then
    statsNumFilesFound = statsNumFilesFound +
      scrape_files(escape_path(mount_root).."/*/DCIM/*", dcimDestRoot, nil, transactions)
  else
    dt.print(dcimDestRoot.." is not mounted. Will only import from inboxes.")
  end
  
  --Handle user sorted 'inbox' import
  for _, altConf in pairs(alternate_dests) do
    local dir = altConf[1]
    local dirStructure = altConf[2]
    
    local testAltDirExists = "test -d '"..dir.."'"
    local altDirExists = os.execute(testAltDirExists)
    if (altDirExists == true) then
      local ensureInboxExistsCommand = "mkdir -p '"..dir.."/"..alternate_inbox_name.."'"
      coroutine.yield("RUN_COMMAND", ensureInboxExistsCommand)
      
      statsNumFilesFound = statsNumFilesFound +
        scrape_files(escape_path(dir).."/"..escape_path(alternate_inbox_name), dir, dirStructure, transactions)
    else
      dt.print(dir.." could not be found and was skipped over.")
    end
  end
  
  --Read image metadata and copy/move
  local copy_progress_job = dt.gui.create_job ("Copying images", true)
  
  --Separate loop for load, so that, in case of error, copying/moving the images
  --will not fail halfway through
  for _,tr in pairs(transactions) do
    --TODO rapportera progress
    tr:load()
    
    statsNumFilesScanned = statsNumFilesScanned + 1
    copy_progress_job.percent = (statsNumFilesScanned*0.5) / statsNumFilesFound
  end
  
  for _,tr in pairs(transactions) do
    if (tr.type =='image') then
      statsNumImagesFound = statsNumImagesFound + 1
      local destDir = tr:copy_image()
      if (destDir ~= nil) then
        changedDirs[destDir] = true
      else
        statsNumImagesDuplicate = statsNumImagesDuplicate + 1
      end
    end
    statsNumFilesCopied = statsNumFilesCopied + 1
    copy_progress_job.percent = 0.5 + (statsNumFilesCopied*0.5) / statsNumFilesFound
  end
  
  copy_progress_job.valid = false
  
  --Tell Darktable to import images
  for dir,_ in pairs(changedDirs) do
    dt.database.import(dir)
  end
  
  --Build completion user message and display it
  if (statsNumFilesFound > 0) then
    local completionMessage = ""
    if (statsNumImagesFound > 0) then
      completionMessage = statsNumImagesFound.." images imported."
      if (statsNumImagesDuplicate > 0) then
        completionMessage = completionMessage.." ".." of which "..statsNumImagesDuplicate.." had already been copied."
      end
    end
    if (statsNumFilesFound > statsNumImagesFound) then
      local numFilesIgnored = statsNumFilesFound - statsNumImagesFound
      completionMessage = completionMessage.." "..numFilesIgnored.." unsupported files were ignored."
    end
    dt.print(completionMessage)
  else
    dt.print("No DCF files found. Is your memory card not mounted, or empty?")
  end
end

-------- Darktable registration --------

local alternate_dests_paths = {}
for _,conf in pairs(alternate_dests) do
  table.insert(alternate_dests_paths, conf[1])
end

dt.preferences.register("copy_import", "FolderPattern", "string", "Copy import: default folder naming structure for imports", "Create a folder structure within the import destination folder. Available variables: ${year}, ${month}, ${day}. Original filename is appended at the end.", "${year}/${month}/${day}" )
if(using_multiple_dests) then
  dt.preferences.register("copy_import", "DCFImportDirectorySelect", "enum", "Copy import: which of the destination folders to import mounted flash memories (DCF) to", "Select which folder (from your own multi-import list) that will be used for importing directly from mounted camera flash storage.", alternate_dests_paths[1], unpack(alternate_dests_paths) )
else
  dt.preferences.register("copy_import", "DCFImportDirectoryBrowse", "directory", "Copy import: root folder to import to (photo library)", "Choose the folder that will be used for importing directly from mounted camera flash storage.", "/" )
end
dt.register_event("shortcut",copy_import, "Copy and import images from memory cards and '"..alternate_inbox_name.."' folders")